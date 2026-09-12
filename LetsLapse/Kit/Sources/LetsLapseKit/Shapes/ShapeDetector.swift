import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import Vision
import simd

// Finds dominant ellipses and quads in one picture. Takes a CGImage, or a
// preview pixel buffer plus the orientation that makes it upright (the live
// viewfinder pass in Photo mode). Method and gates from the shape-sequence
// spike: quads via `VNDetectRectanglesRequest`, ellipses via Vision contours
// (dark/light × contrast sweep, plus a thresholded CIEdges map) → polygon
// reject → Halir–Flusser fit → residual / coverage / obliquity / size gates →
// overlap dedupe.
//
// Vision serialises every contour request in a process through one queue and
// its tracer is superlinear in `maximumImageDimension` (512 ≈ 1–2 s per photo
// for the passes below, 1024 ≈ 30×); the tracer stays at 512 while the picture
// handed over is 1024. The `live` profile below is the same machine cut down
// to one contour pass at 384 px so it can run a few times a second on a phone.

public struct ShapeDetector: Sendable {
    public struct Settings: Sendable {
        public var detectionLongEdge = 1024
        public var contourImageDimension = 512
        /// Which halves of the machine to run — see `ShapeSearch.Family`.
        public var detectQuads = true
        public var detectEllipses = true
        public var minNativeDiameterPx = 400.0
        public var minDiameterFractionOfShortEdge = 1.0 / 6.0
        /// Ceiling on a shape's diameter as a share of the short edge (1 = none
        /// beyond the frame-filling rule below).
        public var maxDiameterFractionOfShortEdge = 1.0
        /// 0.04 rather than the spike's 0.03: on the catalogue the extra 1 % admitted
        /// one true clock face and no false positive (docs/shape-sequence-spike/report.md).
        public var maxFitResidual = 0.04
        public var minCoverage = 0.70
        public var minObliquity = 0.25
        public var contrastAdjustments: [Float] = [1.0, 2.0, 3.0]
        public var edgeThresholds: [Float] = [0.06, 0.15]
        public var rectMinimumAspectRatio: Float = 0.3
        public var rectMaximumObservations = 12
        public var rectMinimumConfidence: Float = 0.6
        public var rectQuadratureTolerance: Float = 30
        /// Edge support a quad needs to be believed: the fraction of points
        /// sampled along its four sides that have an edge under them.
        /// `VNDetectRectanglesRequest` happily reads a circle's silhouette as
        /// a rounded square — its straight sides then touch the circle at
        /// four points and cross blank picture everywhere else — and reports
        /// quads over blank sky and night shadows with no edge under them at
        /// all (the spike's false positives). Measured 2026-09-11: real
        /// windows and a speaker box score 0.55–1.0, the squares Vision drew
        /// around two round coasters 0.00–0.20. Whole perimeter only — a real
        /// window's top side is often in shadow or follows a curtain, so a
        /// per-side floor (tried at 0.1–0.3) threw away real rectangles.
        /// 0 disables the gate.
        public var quadEdgeSupport = 0.45
        public var quadEdgeSupportPerSide = 0.0
        /// CIEdges threshold for the support map.
        public var quadEdgeThreshold: Float = 0.08
        /// The edge-point circle pass (see `EdgeCircleDetector`): circles the
        /// contour tracer cannot close — ribbed medallions, clock faces,
        /// manhole covers. Support is the share of the rim with a radial edge
        /// point on it; coverage the share of the 36 angular bins those points
        /// fill (an arch has half). `edgeCircleMaxResidual` is the fit gate
        /// on the rim's own points, looser than the contour path's because
        /// edge points sit a pixel either side of the rim by construction.
        public var edgeCircles = true
        public var edgeCircleMinSupport = 0.35
        /// Coverage counts a bin from its second point (a stray edge crossing
        /// the rim does not fill one); the gap is the largest run of empty
        /// bins — an arch has 18 of 36.
        public var edgeCircleMinCoverage = 0.55
        public var edgeCircleMaxGapBins = 6
        public var edgeCircleMaxWideHoles = 2
        public var edgeCirclePercentile = 0.85
        public var edgeCircleMaxResidual = 0.08
        /// Which contour polarities to trace: dark shapes on light, light on
        /// dark, or (the default) both.
        public var polarities: [Bool] = [true, false]
        /// The region-proposal pass (`RegionProposals`): the benchmark
        /// reference's maps and §3 fits, run after the Vision passes and
        /// admitted where they found nothing. About a second per picture on a
        /// phone, so the file pass only — `live` turns it off.
        public var regionProposals = true
        /// The long edges the region pass traces at; proposals from every
        /// scale are unioned. 1024 alone found 26 of the benchmark's 68
        /// labels, 1024 + 2048 found 31 (a small plate's corners are corners
        /// at 2048 and a blur at 1024) for about a second more per picture
        /// on an M4 Mac. The input picture is downscaled to each; a scale
        /// above the input's own size runs at the input's size.
        public var regionProposalLongEdges = [1024, 2048]
        /// The region pass's own gates (its §3 rules at the detection
        /// resolution). An experiment can loosen them to see what a later,
        /// full-resolution measurement would make of the proposals.
        public var regionEllipseMinIoU = 0.90
        public var regionRectMinFill = 0.85
        public var regionRectAngleToleranceDeg = 8.0
        public var regionRectSideTolerance = 0.10
        public init() {}

        /// The viewfinder pass with the dials at their defaults — see
        /// `ShapeSearch.liveSettings()`. Measured at 25–95 ms per contour pass
        /// on an iPhone 16 Pro (2026-09-11).
        public static var live: Settings { ShapeSearch().liveSettings() }
    }

    public var settings = Settings()
    public init(settings: Settings = Settings()) { self.settings = settings }

    /// What a pass looked at and turned away — the story behind an empty
    /// result, kept with the capture so a miss in the field can be read at
    /// the desk (2026-09-11: a clean clock dial at 5×, High, nothing traced,
    /// and nothing to say why). Refusals are capped at the biggest 24; the
    /// counts are the whole picture.
    public struct Diagnostics: Codable, Equatable, Sendable {
        public struct Refusal: Codable, Equatable, Sendable {
            /// "quad", "ellipse" (a traced contour) or "rim" (an edge-point circle).
            public var kind: String
            /// Normalised centre, top-left origin.
            public var centre: CGPoint
            /// Diameter or longer side as a fraction of the frame's width.
            public var size: Double
            public var reason: String
            /// How far from passing, 0 at the line, 1 at twice the gate —
            /// the trail keeps the nearest misses, which are the ones worth
            /// a look. Hard refusals (border, off-frame) are 1.
            public var margin: Double
            public init(kind: String, centre: CGPoint, size: Double, reason: String, margin: Double = 1) {
                self.kind = kind; self.centre = centre; self.size = size; self.reason = reason; self.margin = margin
            }
        }
        public var longEdge = 0
        public var quadsOffered = 0
        public var quadsKept = 0
        public var contourPasses = 0
        public var contours = 0
        public var ellipseFits = 0
        public var ellipsesKept = 0
        public var rimPeaks = 0
        public var rimsKept = 0
        /// The region-proposal pass: maps traced, regions fitted, shapes admitted.
        public var regionMaps = 0
        public var regions = 0
        public var regionsKept = 0
        public var milliseconds = 0
        public var refusals: [Refusal] = []
        public init() {}

        private enum CodingKeys: String, CodingKey {
            case longEdge, quadsOffered, quadsKept, contourPasses, contours, ellipseFits, ellipsesKept, rimPeaks, rimsKept
            case regionMaps, regions, regionsKept, milliseconds, refusals
        }

        /// Registers written before the region pass carry no counters for it.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            longEdge = try c.decodeIfPresent(Int.self, forKey: .longEdge) ?? 0
            quadsOffered = try c.decodeIfPresent(Int.self, forKey: .quadsOffered) ?? 0
            quadsKept = try c.decodeIfPresent(Int.self, forKey: .quadsKept) ?? 0
            contourPasses = try c.decodeIfPresent(Int.self, forKey: .contourPasses) ?? 0
            contours = try c.decodeIfPresent(Int.self, forKey: .contours) ?? 0
            ellipseFits = try c.decodeIfPresent(Int.self, forKey: .ellipseFits) ?? 0
            ellipsesKept = try c.decodeIfPresent(Int.self, forKey: .ellipsesKept) ?? 0
            rimPeaks = try c.decodeIfPresent(Int.self, forKey: .rimPeaks) ?? 0
            rimsKept = try c.decodeIfPresent(Int.self, forKey: .rimsKept) ?? 0
            regionMaps = try c.decodeIfPresent(Int.self, forKey: .regionMaps) ?? 0
            regions = try c.decodeIfPresent(Int.self, forKey: .regions) ?? 0
            regionsKept = try c.decodeIfPresent(Int.self, forKey: .regionsKept) ?? 0
            milliseconds = try c.decodeIfPresent(Int.self, forKey: .milliseconds) ?? 0
            refusals = try c.decodeIfPresent([Refusal].self, forKey: .refusals) ?? []
        }

        mutating func refuse(_ kind: String, _ centre: CGPoint, _ size: Double, _ reason: String, margin: Double = 1) {
            refusals.append(Refusal(kind: kind, centre: centre, size: size, reason: reason, margin: max(0, min(1, margin))))
        }

        /// The 24 nearest misses, the rest dropped — a textured wall offers
        /// hundreds of hopeless fits and none of them is the story.
        mutating func trim() {
            refusals.sort { $0.margin == $1.margin ? $0.size > $1.size : $0.margin < $1.margin }
            if refusals.count > 24 { refusals = Array(refusals.prefix(24)) }
        }

        /// One line per refusal, for a log or the CLI.
        public var summary: String {
            "\(quadsOffered) quads offered, \(quadsKept) kept · \(contours) contours over \(contourPasses) passes, \(ellipseFits) fits, \(ellipsesKept) ellipses · \(rimPeaks) rim peaks, \(rimsKept) rims"
            + (regionMaps > 0 ? " · \(regions) regions over \(regionMaps) maps, \(regionsKept) admitted" : "")
            + " · \(milliseconds) ms"
        }
    }

    /// `image` may be any size (it is downscaled to `detectionLongEdge`);
    /// `nativeSize` is the frame's oriented pixel size, which the size gate and
    /// `nativeDiameterPx` are measured in.
    public func detect(in input: CGImage, nativeSize: CGSize) throws -> [DetectedShape] {
        try detectWithDiagnostics(in: input, nativeSize: nativeSize).shapes
    }

    /// The same pass, with what it turned away.
    public func detectWithDiagnostics(in input: CGImage, nativeSize: CGSize) throws -> (shapes: [DetectedShape], diagnostics: Diagnostics) {
        var diag = Diagnostics()
        let started = Date()
        defer { _ = started }
        let image = Self.downscale(input, longEdge: settings.detectionLongEdge)
        diag.longEdge = max(image.width, image.height)
        let w = Double(image.width), h = Double(image.height)
        let nativeScale = Double(nativeSize.width) / w
        let shortEdgeNative = Double(min(nativeSize.width, nativeSize.height))
        let minDiameterNative = max(settings.minNativeDiameterPx, shortEdgeNative * settings.minDiameterFractionOfShortEdge)
        let maxDiameterNative = shortEdgeNative * min(1, settings.maxDiameterFractionOfShortEdge)
        let minDiameterDet = minDiameterNative / nativeScale
        var out: [DetectedShape] = []

        // Quads.
        if settings.detectQuads {
            let rect = VNDetectRectanglesRequest()
            rect.minimumAspectRatio = settings.rectMinimumAspectRatio
            rect.maximumAspectRatio = 1.0
            rect.maximumObservations = settings.rectMaximumObservations
            rect.minimumConfidence = settings.rectMinimumConfidence
            rect.quadratureTolerance = settings.rectQuadratureTolerance
            rect.minimumSize = 0.08
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([rect])
            var quads: [DetectedShape] = []
            diag.quadsOffered = rect.results?.count ?? 0
            let supportMap = settings.quadEdgeSupport > 0 ? Self.edgeMap(image, threshold: settings.quadEdgeThreshold) : nil
            let support = supportMap.flatMap(EdgeSupport.init)
            if let supportMap, let dump = ProcessInfo.processInfo.environment["LAPSE_SHAPES_DEBUG"], dump.hasSuffix(".png"),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dump) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, supportMap, nil)
                CGImageDestinationFinalize(dest)
            }
            for obs in rect.results ?? [] {
                let pts = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
                let px = pts.map { CGPoint(x: $0.x * w, y: $0.y * h) }
                let metrics = DetectedShape.quadMetrics(cornersPx: px)
                let major = metrics.major, minor = metrics.minor
                let margin = 0.03
                let onBorder = pts.allSatisfy { p in (p.x < margin || p.x > 1 - margin) && (p.y < margin || p.y > 1 - margin) }
                let quadCentre = CGPoint(x: (pts[0].x + pts[1].x + pts[2].x + pts[3].x) / 4, y: (pts[0].y + pts[1].y + pts[2].y + pts[3].y) / 4)
                if onBorder { diag.refuse("quad", quadCentre, major / w, "on the frame's border"); continue }
                if major * nativeScale < minDiameterNative {
                    diag.refuse("quad", quadCentre, major / w, String(format: "%.0f px < %.0f floor", major * nativeScale, minDiameterNative), margin: 1 - major * nativeScale / minDiameterNative); continue
                }
                if major * nativeScale > maxDiameterNative {
                    diag.refuse("quad", quadCentre, major / w, String(format: "%.0f px > %.0f ceiling", major * nativeScale, maxDiameterNative)); continue
                }
                if let support {
                    // ±0.5 % of the long edge: Vision's sides land 0–5 px off the
                    // real edge at 1024 (measured on windows and the test card).
                    let (whole, weakest) = support.alongSides(px, tolerance: max(2, Int(max(w, h)) / 200))
                    if ProcessInfo.processInfo.environment["LAPSE_SHAPES_DEBUG"] != nil {
                        print(String(format: "  quad at (%.2f, %.2f) %.0f×%.0f: support %.2f whole, %.2f weakest, conf %.2f; map %d×%d rowBytes %d; corners px %@",
                                     (pts[0].x + pts[2].x) / 2, (pts[0].y + pts[2].y) / 2, major, minor, whole, weakest, obs.confidence,
                                     support.width, support.height, support.bytesPerRow,
                                     px.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }.joined(separator: " ") as NSString))
                        // Each side's midpoint: how far to the nearest edge pixel (search ±12 px).
                        var report: [String] = []
                        for i in 0..<4 {
                            let a = px[i], b = px[(i + 1) % 4]
                            let mx = Int((a.x + b.x) / 2), my = Int((a.y + b.y) / 2)
                            var nearest = -1
                            outer: for r in 0...12 {
                                for dy in -r...r { for dx in -r...r where support.isEdge(mx + dx, my + dy) { nearest = r; break outer } }
                            }
                            report.append("side \(i) mid (\(mx),\(my)) nearest edge \(nearest)")
                        }
                        print("    " + report.joined(separator: "; "))
                    }
                    if whole < settings.quadEdgeSupport || weakest < settings.quadEdgeSupportPerSide {
                        diag.refuse("quad", quadCentre, major / w, String(format: "edge support %.2f < %.2f", whole, settings.quadEdgeSupport), margin: 1 - whole / settings.quadEdgeSupport); continue
                    }
                }
                let centre = CGPoint(x: (pts[0].x + pts[1].x + pts[2].x + pts[3].x) / 4, y: (pts[0].y + pts[1].y + pts[2].y + pts[3].y) / 4)
                quads.append(DetectedShape(kind: .quad, centre: centre, majorAxis: major / w, minorAxis: minor / w,
                                           rotation: metrics.rotation, corners: pts, confidence: obs.confidence,
                                           nativeDiameterPx: major * nativeScale, wide: metrics.wide))
            }
            out += Self.dedupe(quads.sorted { $0.confidence > $1.confidence })
            diag.quadsKept = out.count
        }
        var keptEllipses: [DetectedShape] = []
        if settings.detectEllipses {
            keptEllipses = try traceEllipses(image, w: w, h: h, nativeScale: nativeScale, minDiameterDet: minDiameterDet,
                                             minDiameterNative: minDiameterNative, maxDiameterNative: maxDiameterNative, diag: &diag)
        }
        diag.ellipsesKept = keptEllipses.count - diag.rimsKept
        // One object, one shape. A quad over the same bounds as an ellipse is
        // the rectangle request reading the ellipse's silhouette (a circle's
        // circumscribed square), and the ellipse — residual-gated, fitted to
        // the outline — is the more specific claim. Second guard after the
        // edge-support gate: a large oval's cage can still score up to ~0.4
        // there, this one does not depend on the number.
        for quad in out where keptEllipses.contains(where: { Self.overlap($0, quad) >= 0.6 }) {
            diag.refuse("quad", quad.centre, quad.majorAxis, "the same bounds as an ellipse")
            diag.quadsKept -= 1
        }
        out.removeAll { quad in keptEllipses.contains { Self.overlap($0, quad) >= 0.6 } }
        out += keptEllipses

        // Region proposals, where the passes above found nothing: the
        // benchmark reference's maps and fits (see `RegionProposals`).
        if settings.regionProposals {
            var rs = RegionProposals.Settings()
            rs.ellipseMinIoU = settings.regionEllipseMinIoU
            rs.rectMinFill = settings.regionRectMinFill
            rs.rectAngleToleranceDeg = settings.regionRectAngleToleranceDeg
            rs.rectSideTolerance = settings.regionRectSideTolerance
            var scaled: [(RegionProposals.Candidate, Double)] = []   // candidate, its frame's px per detection px
            var edgesDone: Set<Int> = []
            for edge in settings.regionProposalLongEdges.sorted(by: >) {
                let picture = edge == Int(max(w, h)) ? image : Self.downscale(input, longEdge: edge)
                let pw = picture.width, ph = picture.height
                guard edgesDone.insert(max(pw, ph)).inserted, let gray = RegionProposals.grayPlane(picture) else { continue }
                let regions = RegionProposals.detect(in: gray, settings: rs)
                diag.regionMaps += regions.maps
                diag.regions += regions.regions
                let factor = Double(pw) / w
                for r in regions.refusals {
                    diag.refuse("region", CGPoint(x: r.centre.x / Double(pw), y: r.centre.y / Double(ph)), r.size * Double(max(pw, ph)) / Double(pw), r.reason, margin: r.margin)
                }
                for c in regions.candidates { scaled.append((c, factor)) }
            }
            scaled.sort { $0.0.score > $1.0.score }
            for (c, factor) in scaled {
                let shape: DetectedShape
                switch c.primitive {
                case .rectangle:
                    guard settings.detectQuads, let corners = c.corners, corners.count == 4 else { continue }
                    let px = corners.map { CGPoint(x: $0.x / factor, y: $0.y / factor) }
                    let m = DetectedShape.quadMetrics(cornersPx: px)
                    let centre = CGPoint(x: px.map(\.x).reduce(0, +) / 4 / w, y: px.map(\.y).reduce(0, +) / 4 / h)
                    let major = m.major
                    if major * nativeScale < minDiameterNative {
                        diag.refuse("region", centre, major / w, String(format: "%.0f px < %.0f floor", major * nativeScale, minDiameterNative), margin: 1 - major * nativeScale / minDiameterNative); continue
                    }
                    if major * nativeScale > maxDiameterNative {
                        diag.refuse("region", centre, major / w, String(format: "%.0f px > %.0f ceiling", major * nativeScale, maxDiameterNative)); continue
                    }
                    shape = DetectedShape(kind: .quad, centre: centre, majorAxis: major / w, minorAxis: m.minor / w,
                                          rotation: m.rotation, corners: px.map { CGPoint(x: $0.x / w, y: $0.y / h) },
                                          confidence: Float(c.score), nativeDiameterPx: major * nativeScale, wide: m.wide)
                case .ellipse:
                    guard settings.detectEllipses, var e = c.ellipse else { continue }
                    e.centre /= factor; e.semiMajor /= factor; e.semiMinor /= factor
                    let centre = CGPoint(x: e.centre.x / w, y: e.centre.y / h)
                    let diameter = 2 * e.semiMajor
                    if diameter * nativeScale < minDiameterNative {
                        diag.refuse("region", centre, diameter / w, String(format: "%.0f px < %.0f floor", diameter * nativeScale, minDiameterNative), margin: 1 - diameter * nativeScale / minDiameterNative); continue
                    }
                    if diameter * nativeScale > maxDiameterNative {
                        diag.refuse("region", centre, diameter / w, String(format: "%.0f px > %.0f ceiling", diameter * nativeScale, maxDiameterNative)); continue
                    }
                    if 2 * e.semiMajor > 0.97 * max(w, h) && 2 * e.semiMinor > 0.97 * min(w, h) { diag.refuse("region", centre, diameter / w, "fills the frame"); continue }
                    shape = DetectedShape(kind: .ellipse, centre: centre, majorAxis: diameter / w, minorAxis: 2 * e.semiMinor / w,
                                          rotation: e.rotation, corners: nil, confidence: Float(c.score), nativeDiameterPx: diameter * nativeScale)
                }
                // The Vision passes' shapes stand; a region over the same
                // bounds is the same shape seen again (a nested member is not).
                if out.contains(where: { Self.overlap($0, shape) > Self.sameShapeIoU }) {
                    diag.refuse("region", shape.centre, shape.majorAxis, "the same bounds as a kept shape"); continue
                }
                out.append(shape)
                diag.regionsKept += 1
            }
        }
        diag.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        diag.trim()
        return (out, diag)
    }

    /// The ellipse half of the Vision machine: contour passes, then the
    /// edge-point circles where the tracer found nothing.
    private func traceEllipses(_ image: CGImage, w: Double, h: Double, nativeScale: Double, minDiameterDet: Double,
                               minDiameterNative: Double, maxDiameterNative: Double, diag: inout Diagnostics) throws -> [DetectedShape] {
        // Ellipses: region contours, then edge-map contours.
        var passes: [(CGImage, Float, Bool)] = []
        for dark in settings.polarities { for ca in settings.contrastAdjustments { passes.append((image, ca, dark)) } }
        for thr in settings.edgeThresholds {
            if let edges = Self.edgeMap(image, threshold: thr) { passes.append((edges, 1.0, false)) }
        }
        var ellipses: [(DetectedShape, Double)] = []
        for (source, contrast, dark) in passes {
            let req = VNDetectContoursRequest()
            req.contrastAdjustment = contrast
            req.detectsDarkOnLight = dark
            req.maximumImageDimension = settings.contourImageDimension
            try VNImageRequestHandler(cgImage: source, options: [:]).perform([req])
            diag.contourPasses += 1
            guard let obs = req.results?.first else { continue }
            diag.contours += obs.contourCount
            for i in 0..<obs.contourCount {
                guard let contour = try? obs.contour(at: i) else { continue }
                let npts = contour.normalizedPoints
                guard npts.count >= 24 else { continue }
                var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
                var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
                for p in npts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
                if max(Double(maxX - minX) * w, Double(maxY - minY) * h) < minDiameterDet * 0.9 { continue }
                if let approx = try? contour.polygonApproximation(epsilon: 0.004), approx.pointCount <= 6 { continue }
                let pts = npts.map { SIMD2<Double>(Double($0.x) * w, (1 - Double($0.y)) * h) }
                guard let e = EllipseFit.fit(pts) else { continue }
                diag.ellipseFits += 1
                let q = EllipseFit.quality(e, pts)
                let ec = CGPoint(x: e.centre.x / w, y: e.centre.y / h), esize = 2 * e.semiMajor / w
                if simd_length(pts[0] - pts[pts.count - 1]) > 0.05 * 2 * e.semiMajor { diag.refuse("ellipse", ec, esize, "open contour"); continue }
                if q.residual > settings.maxFitResidual { diag.refuse("ellipse", ec, esize, String(format: "residual %.3f > %.3f", q.residual, settings.maxFitResidual), margin: q.residual / settings.maxFitResidual - 1); continue }
                if q.coverage < settings.minCoverage { diag.refuse("ellipse", ec, esize, String(format: "coverage %.2f < %.2f", q.coverage, settings.minCoverage), margin: 1 - q.coverage / settings.minCoverage); continue }
                if e.ratio < settings.minObliquity { diag.refuse("ellipse", ec, esize, String(format: "obliquity %.2f < %.2f", e.ratio, settings.minObliquity), margin: 1 - e.ratio / settings.minObliquity); continue }
                if 2 * e.semiMajor * nativeScale < minDiameterNative { diag.refuse("ellipse", ec, esize, String(format: "%.0f px < %.0f floor", 2 * e.semiMajor * nativeScale, minDiameterNative), margin: 1 - 2 * e.semiMajor * nativeScale / minDiameterNative); continue }
                if 2 * e.semiMajor * nativeScale > maxDiameterNative { diag.refuse("ellipse", ec, esize, String(format: "%.0f px > %.0f ceiling", 2 * e.semiMajor * nativeScale, maxDiameterNative)); continue }
                if e.centre.x < 0 || e.centre.x > w || e.centre.y < 0 || e.centre.y > h { diag.refuse("ellipse", ec, esize, "centre off the frame"); continue }
                if 2 * e.semiMajor > 0.97 * max(w, h) && 2 * e.semiMinor > 0.97 * min(w, h) { diag.refuse("ellipse", ec, esize, "fills the frame"); continue }
                let conf = Float(max(0, min(1, q.coverage * (1 - q.residual / settings.maxFitResidual))))
                ellipses.append((DetectedShape(kind: .ellipse, centre: CGPoint(x: e.centre.x / w, y: e.centre.y / h),
                                               majorAxis: 2 * e.semiMajor / w, minorAxis: 2 * e.semiMinor / w,
                                               rotation: e.rotation, corners: nil, confidence: conf,
                                               nativeDiameterPx: 2 * e.semiMajor * nativeScale), q.residual))
            }
        }
        var keptEllipses = Self.dedupe(ellipses.sorted { $0.1 < $1.1 }.map { $0.0 })

        // Edge-point circles, where the tracer found nothing.
        if settings.edgeCircles {
            let houghEdge = min(settings.detectionLongEdge, 512)
            let houghScale = min(1, Double(houghEdge) / max(w, h))
            var hs = EdgeCircleDetector.Settings()
            hs.longEdge = houghEdge
            hs.minRadius = max(6, minDiameterDet / 2 * houghScale)
            hs.maxRadius = min(maxDiameterNative / nativeScale, 0.97 * min(w, h)) / 2 * houghScale
            hs.edgePercentile = settings.edgeCirclePercentile
            hs.minSupport = settings.edgeCircleMinSupport
            hs.minCoverage = settings.edgeCircleMinCoverage
            hs.maxGapBins = settings.edgeCircleMaxGapBins
            hs.maxWideHoles = settings.edgeCircleMaxWideHoles
            var exclusions: [EdgeCircleDetector.Exclusion] = []
            for e in keptEllipses {
                let cx: Double = Double(e.centre.x) * w * houghScale
                let cy: Double = Double(e.centre.y) * h * houghScale
                let semiMajor: Double = e.majorAxis * w * 0.5 * houghScale
                let semiMinor: Double = e.minorAxis * w * 0.5 * houghScale
                exclusions.append(EdgeCircleDetector.Exclusion(centre: SIMD2<Double>(cx, cy), semiMajor: semiMajor,
                                                               semiMinor: semiMinor, rotation: e.rotation))
            }
            let rims = EdgeCircleDetector.detect(in: image, settings: hs, exclusions: exclusions)
            diag.rimPeaks = rims.peaks
            for r in rims.refusals {
                diag.refuse("rim", CGPoint(x: r.centre.x / houghScale / w, y: r.centre.y / houghScale / h), 2 * r.radius / houghScale / w, r.reason, margin: r.margin)
            }
            for circle in rims.circles {
                // Back to the detection picture's pixels, then the same fit
                // as the contour path on the rim's own points — a rim seen a
                // little off-axis comes back as the ellipse it is. A fit
                // worse than the gate falls back to the circle the votes
                // found.
                let pts = circle.points.map { $0 / houghScale }
                var centre = circle.centre / houghScale
                var a = circle.radius / houghScale, b = a, rot = 0.0
                if let e = EllipseFit.fit(pts) {
                    let q = EllipseFit.quality(e, pts)
                    if q.residual <= settings.edgeCircleMaxResidual, q.coverage >= settings.edgeCircleMinCoverage,
                       e.ratio >= 0.6, abs(e.semiMajor - a) < 0.35 * a {
                        centre = e.centre; a = e.semiMajor; b = e.semiMinor; rot = e.rotation
                    }
                }
                let rc = CGPoint(x: centre.x / w, y: centre.y / h)
                if 2 * a * nativeScale < minDiameterNative || 2 * a * nativeScale > maxDiameterNative {
                    diag.refuse("rim", rc, 2 * a / w, String(format: "%.0f px outside %.0f–%.0f", 2 * a * nativeScale, minDiameterNative, maxDiameterNative)); continue
                }
                if centre.x < 0 || centre.x > w || centre.y < 0 || centre.y > h { diag.refuse("rim", rc, 2 * a / w, "centre off the frame"); continue }
                let shape = DetectedShape(kind: .ellipse, centre: CGPoint(x: centre.x / w, y: centre.y / h),
                                          majorAxis: 2 * a / w, minorAxis: 2 * b / w, rotation: rot, corners: nil,
                                          confidence: Float(min(1, circle.support) * circle.coverage),
                                          nativeDiameterPx: 2 * a * nativeScale)
                // One rim, one shape. The tracer's own ellipse over the same
                // rim stands (residual-gated on a closed outline, the tighter
                // claim), and so does an earlier, better-supported circle: a
                // scalloped or ribbed rim votes for centres a lobe's width
                // off its own as well, with much of the same perimeter
                // behind them — a near-copy whose centre is off by more than
                // a tenth of the radius is a lobe vote. Concentric rings are
                // members of a nest and all stand (flat policy, see
                // `sameShapeIoU`); only a near-identical one is the same rim.
                let sameRim = keptEllipses.contains { other in
                    let r1 = other.majorAxis * w / 2, r2 = a
                    let distance = hypot((other.centre.x * w) - centre.x, (other.centre.y * h) - centre.y)
                    let ratio = min(r1, r2) / max(r1, r2)
                    let lobeVote = distance > 0.1 * max(r1, r2) && distance < 0.6 * max(r1, r2) && ratio > 0.85
                    return Self.overlap(other, shape) > Self.sameShapeIoU || lobeVote
                }
                if sameRim { diag.refuse("rim", rc, 2 * a / w, "same rim as a kept ellipse"); continue }
                keptEllipses.append(shape)
                diag.rimsKept += 1
            }
        }
        return keptEllipses
    }

    /// A preview frame straight off the camera: the buffer arrives in the
    /// sensor's own landscape and `orientation` is the turn that makes it
    /// upright (the pose the still would be tagged with), so the shapes come
    /// back normalised to the *upright* frame — the same space a detection on
    /// the captured file lands in. `nativeSize` defaults to that upright
    /// buffer size, which with the `live` profile is what the size gate wants.
    public func detect(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                       nativeSize: CGSize? = nil) throws -> [DetectedShape] {
        guard let image = Self.uprightImage(buffer, orientation: orientation,
                                            longEdge: settings.detectionLongEdge) else { return [] }
        let native = nativeSize ?? Self.uprightSize(of: buffer, orientation: orientation)
        return try detect(in: image, nativeSize: native)
    }

    /// The buffer's pixel size once turned upright — a quarter turn swaps the sides.
    public static func uprightSize(of buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGSize {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: return CGSize(width: h, height: w)
        default: return CGSize(width: w, height: h)
        }
    }

    /// The buffer turned upright and scaled so its long edge is `longEdge`, as
    /// one Core Image render. Rendered rather than handed to Vision as a
    /// buffer-plus-orientation so every pass — including the CIEdges maps a
    /// fuller profile adds — sees one upright picture and reports in one space.
    public static func uprightImage(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                                    longEdge: Int) -> CGImage? {
        var ci = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let extent = ci.extent
        let scale = Double(longEdge) / Double(max(extent.width, extent.height))
        if scale < 1 {
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let target = ci.extent.integral
        return context.createCGImage(ci, from: target, format: .RGBA8, colorSpace: srgb)
    }

    /// Two shapes are the same shape when their bounds overlap at least this
    /// much: 0.9 is one edge traced twice (a contrast sweep, both sides of a
    /// thin line — radii within ~5 %). Anything looser merges the members of
    /// a nest — a sign's rim and its disc are 8 % apart in radius and overlap
    /// at 0.85 — and the policy (Steven, 2026-09-12) is flat: every member the
    /// passes can measure is a shape in the register, and whoever needs one
    /// per object takes the biggest. Until then this was 0.5, which kept
    /// whichever member scored higher, not the outer one.
    static let sameShapeIoU = 0.9

    /// Keep the best of near-identical shapes (input already sorted best-first).
    static func dedupe(_ sorted: [DetectedShape]) -> [DetectedShape] {
        var kept: [DetectedShape] = []
        for c in sorted where !kept.contains(where: { iou(bbox($0), bbox(c)) > sameShapeIoU }) { kept.append(c) }
        return kept
    }

    /// The shape's axis-aligned bounds in its normalised frame — public so the
    /// viewfinder tracker and the register's reconcile pass match shapes the
    /// way the detector dedupes them.
    public static func bounds(of a: DetectedShape) -> CGRect { bbox(a) }

    /// Intersection over union of two shapes' bounds.
    public static func overlap(_ a: DetectedShape, _ b: DetectedShape) -> Double { iou(bbox(a), bbox(b)) }

    static func bbox(_ a: DetectedShape) -> CGRect {
        if let c = a.corners { return ShapePolygon.bounds(c) }
        let c = cos(a.rotation), s = sin(a.rotation)
        let ax = a.majorAxis / 2, bx = a.minorAxis / 2
        let hw = sqrt(ax * ax * c * c + bx * bx * s * s)
        let hh = sqrt(ax * ax * s * s + bx * bx * c * c)
        return CGRect(x: a.centre.x - hw, y: a.centre.y - hh, width: 2 * hw, height: 2 * hh)
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let ia = Double(i.width * i.height)
        let u = Double(a.width * a.height + b.width * b.height) - ia
        return u > 0 ? ia / u : 0
    }

    /// A binary edge map read back into memory, with the one question the
    /// quad gate asks of it: how much of a polygon's perimeter lies on edges.
    struct EdgeSupport {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: Data

        init?(_ map: CGImage) {
            guard let provider = map.dataProvider, let cf = provider.data else { return nil }
            width = map.width; height = map.height; bytesPerRow = map.bytesPerRow
            data = cf as Data
        }

        func isEdge(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return data[y * bytesPerRow + x * 4] > 127
        }

        /// Fraction of points sampled along each side (every ~2 px) with an
        /// edge within `tolerance` px across the side — the whole perimeter,
        /// and the weakest side. Vision's corners land a few pixels off the
        /// real edge (measured 0–4 px at 1024), which is what the tolerance
        /// absorbs; it is small enough that a circle's circumscribed square
        /// still only scores near its four tangent points.
        func alongSides(_ corners: [CGPoint], tolerance: Int) -> (whole: Double, weakest: Double) {
            guard corners.count == 4 else { return (0, 0) }
            var hitsAll = 0, samplesAll = 0, weakest = 1.0
            for i in 0..<4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > 0 else { return (0, 0) }
                let nx = -(b.y - a.y) / length, ny = (b.x - a.x) / length
                let n = max(8, Int(length / 2))
                var hits = 0
                for k in 0..<n {
                    let t = (Double(k) + 0.5) / Double(n)
                    let x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t
                    for d in -tolerance...tolerance
                    where isEdge(Int((x + nx * Double(d)).rounded()), Int((y + ny * Double(d)).rounded())) {
                        hits += 1
                        break
                    }
                }
                hitsAll += hits; samplesAll += n
                weakest = min(weakest, Double(hits) / Double(n))
            }
            return (samplesAll > 0 ? Double(hitsAll) / Double(samplesAll) : 0, weakest)
        }
    }

    static let context = CIContext(options: [.cacheIntermediates: false])
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Binary edge map: CIEdges → luminance → threshold → dilate (radius 2) so
    /// the lines survive Vision's own downsample to the tracer's resolution.
    static func edgeMap(_ image: CGImage, threshold: Float) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var ci = CIImage(cgImage: image)
        ci = ci.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0])
        ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        ci = ci.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": threshold])
        ci = ci.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2.0])
        return context.createCGImage(ci.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: srgb)
    }

    /// Downscale so the longest edge is `longEdge` (no-op if already smaller).
    public static func downscale(_ image: CGImage, longEdge: Int) -> CGImage {
        let w = image.width, h = image.height
        guard max(w, h) > longEdge else { return image }
        let s = Double(longEdge) / Double(max(w, h))
        let nw = max(1, Int((Double(w) * s).rounded())), nh = max(1, Int((Double(h) * s).rounded()))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }
}

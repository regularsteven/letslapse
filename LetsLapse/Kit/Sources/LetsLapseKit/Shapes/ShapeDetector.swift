import Foundation
import CoreGraphics
import CoreImage
import Vision
import simd

// Finds dominant ellipses and quads in one picture. Takes a CGImage; the
// armed-recording preview would add a CVPixelBuffer overload. Method and
// gates from the shape-sequence spike: quads via `VNDetectRectanglesRequest`,
// ellipses via Vision contours (dark/light × contrast sweep, plus a thresholded
// CIEdges map) → polygon reject → Halir–Flusser fit → residual / coverage /
// obliquity / size gates → overlap dedupe.
//
// Vision serialises every contour request in a process through one queue and
// its tracer is superlinear in `maximumImageDimension` (512 ≈ 1–2 s per photo
// for the passes below, 1024 ≈ 30×); the tracer stays at 512 while the picture
// handed over is 1024.

public struct ShapeDetector: Sendable {
    public struct Settings: Sendable {
        public var detectionLongEdge = 1024
        public var contourImageDimension = 512
        public var minNativeDiameterPx = 400.0
        public var minDiameterFractionOfShortEdge = 1.0 / 6.0
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
        public init() {}
    }

    public var settings = Settings()
    public init(settings: Settings = Settings()) { self.settings = settings }

    /// `image` may be any size (it is downscaled to `detectionLongEdge`);
    /// `nativeSize` is the frame's oriented pixel size, which the size gate and
    /// `nativeDiameterPx` are measured in.
    public func detect(in input: CGImage, nativeSize: CGSize) throws -> [DetectedShape] {
        let image = Self.downscale(input, longEdge: settings.detectionLongEdge)
        let w = Double(image.width), h = Double(image.height)
        let nativeScale = Double(nativeSize.width) / w
        let minDiameterNative = max(settings.minNativeDiameterPx,
                                    Double(min(nativeSize.width, nativeSize.height)) * settings.minDiameterFractionOfShortEdge)
        let minDiameterDet = minDiameterNative / nativeScale
        var out: [DetectedShape] = []

        // Quads.
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
        for obs in rect.results ?? [] {
            let pts = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
            let px = pts.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            let metrics = DetectedShape.quadMetrics(cornersPx: px)
            let major = metrics.major, minor = metrics.minor
            let margin = 0.03
            let onBorder = pts.allSatisfy { p in (p.x < margin || p.x > 1 - margin) && (p.y < margin || p.y > 1 - margin) }
            if onBorder || major * nativeScale < minDiameterNative { continue }
            let centre = CGPoint(x: (pts[0].x + pts[1].x + pts[2].x + pts[3].x) / 4, y: (pts[0].y + pts[1].y + pts[2].y + pts[3].y) / 4)
            quads.append(DetectedShape(kind: .quad, centre: centre, majorAxis: major / w, minorAxis: minor / w,
                                       rotation: metrics.rotation, corners: pts, confidence: obs.confidence,
                                       nativeDiameterPx: major * nativeScale, wide: metrics.wide))
        }
        out += Self.dedupe(quads.sorted { $0.confidence > $1.confidence })

        // Ellipses: region contours, then edge-map contours.
        var passes: [(CGImage, Float, Bool)] = []
        for dark in [true, false] { for ca in settings.contrastAdjustments { passes.append((image, ca, dark)) } }
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
            guard let obs = req.results?.first else { continue }
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
                let q = EllipseFit.quality(e, pts)
                if simd_length(pts[0] - pts[pts.count - 1]) > 0.05 * 2 * e.semiMajor { continue }
                if q.residual > settings.maxFitResidual || q.coverage < settings.minCoverage { continue }
                if e.ratio < settings.minObliquity { continue }
                if 2 * e.semiMajor * nativeScale < minDiameterNative { continue }
                if e.centre.x < 0 || e.centre.x > w || e.centre.y < 0 || e.centre.y > h { continue }
                if 2 * e.semiMajor > 0.97 * max(w, h) && 2 * e.semiMinor > 0.97 * min(w, h) { continue }
                let conf = Float(max(0, min(1, q.coverage * (1 - q.residual / settings.maxFitResidual))))
                ellipses.append((DetectedShape(kind: .ellipse, centre: CGPoint(x: e.centre.x / w, y: e.centre.y / h),
                                               majorAxis: 2 * e.semiMajor / w, minorAxis: 2 * e.semiMinor / w,
                                               rotation: e.rotation, corners: nil, confidence: conf,
                                               nativeDiameterPx: 2 * e.semiMajor * nativeScale), q.residual))
            }
        }
        out += Self.dedupe(ellipses.sorted { $0.1 < $1.1 }.map { $0.0 })
        return out
    }

    /// Keep the best of heavily overlapping shapes (input already sorted best-first).
    static func dedupe(_ sorted: [DetectedShape]) -> [DetectedShape] {
        var kept: [DetectedShape] = []
        for c in sorted where !kept.contains(where: { iou(bbox($0), bbox(c)) > 0.5 }) { kept.append(c) }
        return kept
    }

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

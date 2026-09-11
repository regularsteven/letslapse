import Foundation
import CoreGraphics
import ImageIO
import LetsLapseKit

// lapse shapes — the shape detector on one picture, headless, with its gates
// on the command line. The way to ask "why did the viewfinder / Find shapes
// not trace that circle?" against the actual file: loosen `--residual`, try
// the `--live` profile the Photo viewfinder runs, and read what each pass
// returns. `LAPSE_SHAPES_DEBUG=1` in the environment prints every quad the
// rectangle request offered with its edge support before the gate;
// `LAPSE_SHAPES_DEBUG=<path>.png` also writes the support map there.

func runShapes(path: String, residual: Double?, live: Bool, longEdge: Int?, verbose: Bool,
               contrasts: [Float]? = nil, edges: [Float]? = nil, contourDimension: Int? = nil,
               search: ShapeSearch = ShapeSearch()) throws {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
        fail("could not read \(path)")
    }
    let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
    let native = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

    var profiles: [(String, ShapeDetector.Settings)]
    if live {
        profiles = [("live \(search.token)", search.liveSettings())]
    } else {
        profiles = [("file \(search.token)", search.fileSettings())]
    }
    for i in profiles.indices {
        if let residual { profiles[i].1.maxFitResidual = residual }
        if let longEdge { profiles[i].1.detectionLongEdge = longEdge; profiles[i].1.contourImageDimension = min(longEdge, 512) }
        if let contrasts { profiles[i].1.contrastAdjustments = contrasts }
        if let edges { profiles[i].1.edgeThresholds = edges }
        if let contourDimension { profiles[i].1.contourImageDimension = contourDimension }
    }
    let decodeEdge = profiles.map { $0.1.detectionLongEdge }.max() ?? 1024
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: decodeEdge,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        fail("could not decode \(path)")
    }
    print("\(url.lastPathComponent): \(Int(native.width))×\(Int(native.height)) (orientation \(orientation)), decoded at \(image.width)×\(image.height)")
    for (name, settings) in profiles {
        let started = Date()
        let shapes = try ShapeDetector(settings: settings).detect(in: image, nativeSize: native)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print(String(format: "%@ pass (residual ≤ %.3f, %d px): %d shapes in %d ms", name, settings.maxFitResidual, settings.detectionLongEdge, shapes.count, ms))
        for s in shapes {
            let cx = Double(s.centre.x) * Double(native.width), cy = Double(s.centre.y) * Double(native.height)
            print(String(format: "  %-9@ %-9@ centre (%.0f, %.0f) px  %.0f × %.0f px  rot %.1f°  conf %.2f",
                         s.family.title as NSString, s.kind.rawValue as NSString, cx, cy,
                         s.majorAxis * Double(native.width), s.minorAxis * Double(native.width),
                         s.rotation * 180 / .pi, Double(s.confidence)))
        }
        if verbose, !live {
            // What the contour tracer saw before the gates: rerun with the
            // gates open and list what the residual gate alone refused.
            var open = settings
            open.maxFitResidual = 1.0
            let all = try ShapeDetector(settings: open).detect(in: image, nativeSize: native)
            let refused = all.filter { a in a.kind == .ellipse && !shapes.contains { ShapeDetector.overlap($0, a) > 0.5 } }
            if !refused.isEmpty {
                print("  refused by the residual gate alone (would pass at residual ≤ 1.0):")
                for s in refused {
                    let cx = Double(s.centre.x) * Double(native.width), cy = Double(s.centre.y) * Double(native.height)
                    print(String(format: "    %-9@ centre (%.0f, %.0f) px  %.0f × %.0f px  conf %.2f",
                                 s.family.title as NSString, cx, cy,
                                 s.majorAxis * Double(native.width), s.minorAxis * Double(native.width), Double(s.confidence)))
                }
            }
        }
    }
}

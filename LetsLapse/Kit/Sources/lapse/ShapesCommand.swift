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

/// `--json`: the pass's shapes and diagnostics as JSON on stdout, for tooling.
struct ShapesJSON: Codable {
    var file: String
    var width: Int
    var height: Int
    var profile: String
    var shapes: [DetectedShape]
    var diagnostics: ShapeDetector.Diagnostics
    var register: ShapeRegister?
}

func runShapes(path: String, residual: Double?, live: Bool, longEdge: Int?, verbose: Bool,
               contrasts: [Float]? = nil, edges: [Float]? = nil, contourDimension: Int? = nil,
               search: ShapeSearch = ShapeSearch(), trail: Bool = false, json: Bool = false,
               regions: Bool? = nil, floor: Double? = nil, regionGates: String? = nil, regionEdges: [Int]? = nil) throws {
    let url = URL(fileURLWithPath: path)
    let projectFolder = url.deletingLastPathComponent().lastPathComponent == "source"
        ? url.deletingLastPathComponent().deletingLastPathComponent() : url.deletingLastPathComponent()
    if trail {
        // The register beside a project's picture: <project>/source/frame.jpg → <project>/shapes.json.
        let folder = url.deletingLastPathComponent().lastPathComponent == "source"
            ? url.deletingLastPathComponent().deletingLastPathComponent() : url.deletingLastPathComponent()
        if let register = ShapeRegister.load(inProjectFolder: folder) {
            print("register: \(register.shapes.count) shape(s)" + (register.analysedAt == nil ? " (provisional)" : "")
                  + (register.representative.horizontalFieldOfView.map { String(format: ", lens %.1f°", $0) } ?? ", lens unknown"))
            for s in register.shapes {
                print(String(format: "  %@ %@ %@  centre (%.2f, %.2f)  %.0f px%@", s.family.title as NSString, s.kind.rawValue as NSString,
                             s.source.rawValue as NSString, s.centre.x, s.centre.y, s.nativeDiameterPx,
                             (s.rectifiedAspect.map { String(format: "  rectified %.3f (as seen %.3f)", $0, s.aspect) } ?? "") as NSString))
            }
            if let t = register.viewfinder {
                print("viewfinder: \(t.summary)")
                if let d = t.lastSample {
                    print("  last live sample: \(d.summary)")
                    for r in d.refusals { print(String(format: "    %@ %d%% at (%.2f, %.2f): %@", r.kind as NSString, Int(r.size * 100), r.centre.x, r.centre.y, r.reason as NSString)) }
                }
                if let d = t.file {
                    print("  file pass: \(d.summary)")
                    for r in d.refusals { print(String(format: "    %@ %d%% at (%.2f, %.2f): %@", r.kind as NSString, Int(r.size * 100), r.centre.x, r.centre.y, r.reason as NSString)) }
                }
            } else {
                print("viewfinder: no trail (Find shapes or a hand-drawn register)")
            }
        } else {
            print("no shapes.json beside \(url.lastPathComponent)")
        }
        // The capture's own conditions, when the shoot wrote them beside the frames.
        let logURL = folder.appendingPathComponent("source").appendingPathComponent(CaptureExposureLog.sessionFileName)
        if let session = try? CaptureExposureLog.loadSession(from: logURL) {
            var line = "capture: \(session.captureMode) on \(session.deviceModel)"
            if let c = session.conditions { line += " — " + c.summary }
            if let f = session.frames.first {
                if let iso = f.iso { line += String(format: " · ISO %.0f", iso) }
                if let t = f.exposureDuration, t > 0 { line += t >= 1 ? String(format: " · %.1f s", t) : String(format: " · 1/%.0f s", 1 / t) }
            }
            print(line)
        }
        print()
    }
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
        if let regions { profiles[i].1.regionProposals = regions; profiles[i].0 += regions ? " +regions" : " -regions" }
        if let regionEdges, !regionEdges.isEmpty {
            profiles[i].1.regionProposalLongEdges = regionEdges
            profiles[i].0 += " regions@" + regionEdges.map(String.init).joined(separator: ",")
        }
        if regionGates == "loose" {
            // Propose only: the §3 gates loosened so a later full-resolution
            // measurement (the benchmark rig's shared pass) decides.
            profiles[i].1.regionEllipseMinIoU = 0.70
            profiles[i].1.regionRectMinFill = 0.70
            profiles[i].1.regionRectAngleToleranceDeg = 20
            profiles[i].1.regionRectSideTolerance = 0.25
            profiles[i].0 += " loose"
        }
        if let floor {
            // An experiment's floor: a share of the short edge, no pixel minimum.
            profiles[i].1.minDiameterFractionOfShortEdge = floor
            profiles[i].1.minNativeDiameterPx = 0
            profiles[i].0 += String(format: " floor %.3f", floor)
        }
        if let residual { profiles[i].1.maxFitResidual = residual }
        if let longEdge { profiles[i].1.detectionLongEdge = longEdge; profiles[i].1.contourImageDimension = min(longEdge, 512) }
        if let contrasts { profiles[i].1.contrastAdjustments = contrasts }
        if let edges { profiles[i].1.edgeThresholds = edges }
        if let contourDimension { profiles[i].1.contourImageDimension = contourDimension }
    }
    let decodeEdge = profiles.map { $0.1.decodeLongEdge }.max() ?? 1024
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: decodeEdge,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        fail("could not decode \(path)")
    }
    if !json { print("\(url.lastPathComponent): \(Int(native.width))×\(Int(native.height)) (orientation \(orientation)), decoded at \(image.width)×\(image.height)") }
    for (name, settings) in profiles {
        let started = Date()
        let (shapes, diagnostics) = try ShapeDetector(settings: settings).detectWithDiagnostics(in: image, nativeSize: native)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if json {
            let out = ShapesJSON(file: path, width: Int(native.width), height: Int(native.height), profile: name,
                                 shapes: shapes, diagnostics: diagnostics, register: ShapeRegister.load(inProjectFolder: projectFolder))
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
            print(String(decoding: try enc.encode(out), as: UTF8.self))
            continue
        }
        print(String(format: "%@ pass (residual ≤ %.3f, %d px): %d shapes in %d ms", name, settings.maxFitResidual, settings.detectionLongEdge, shapes.count, ms))
        for s in shapes {
            let cx = Double(s.centre.x) * Double(native.width), cy = Double(s.centre.y) * Double(native.height)
            print(String(format: "  %-9@ %-9@ centre (%.0f, %.0f) px  %.0f × %.0f px  rot %.1f°  conf %.2f",
                         s.family.title as NSString, s.kind.rawValue as NSString, cx, cy,
                         s.majorAxis * Double(native.width), s.minorAxis * Double(native.width),
                         s.rotation * 180 / .pi, Double(s.confidence)))
        }
        if verbose {
            print("  \(diagnostics.summary)")
            for r in diagnostics.refusals {
                let cx = Double(r.centre.x) * Double(native.width), cy = Double(r.centre.y) * Double(native.height)
                print(String(format: "    refused %@ %.0f px at (%.0f, %.0f): %@", r.kind as NSString, r.size * Double(native.width), cx, cy, r.reason as NSString))
            }
        }
    }
}

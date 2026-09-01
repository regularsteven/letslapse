import CoreGraphics
import CoreImage
import Foundation

/// Semantic regions of a photographed scene. Two today — sky, and its
/// complement — with the enum shaped for the regions a richer model already
/// distinguishes (person, vehicle, building, water…). Scene understanding
/// stays overlay-agnostic: nothing in here knows what it will occlude.
enum SceneRegion: String, Codable, Sendable {
    case sky
    case nonSky

    /// Sky and land are two readings of ONE analysis, not two detectors.
    var complement: SceneRegion {
        switch self {
        case .sky: return .nonSky
        case .nonSky: return .sky
        }
    }
}

/// How the model's grid maps back onto the frame.
enum MaskGeometry: String, Codable, Equatable, Sendable {
    /// The model input was the full frame stretch-resized to the model's
    /// square — no letterbox, no crop — so the grid covers the frame's unit
    /// square exactly and the inverse map is a pure per-axis scale. The
    /// squash is harmless to stuff-class segmentation and removes the whole
    /// family of un-padding misalignment bugs.
    case stretch
}

/// One semantic mask at model-grid resolution: the probability, per grid
/// cell, that the cell belongs to `region`. For an argmax model the
/// probabilities are 0 or 255; a sequence-level mask carries real
/// confidences (the vote fraction across sampled frames).
struct SceneMask: Sendable {
    let region: SceneRegion
    let width: Int
    let height: Int
    /// Row-major, top-left origin, probability × 255.
    let pixels: [UInt8]
    let geometry: MaskGeometry
    /// Where this mask came from — model, input, timing, cache — for the
    /// debug readout.
    let provenance: String

    /// How many distinct values the grid actually holds. An argmax model
    /// returns 2 for a single frame — a hard yes/no per cell — and a
    /// threshold applied to that can only ever be a no-op. A vote across N
    /// frames returns up to N+1. The UI gates the Threshold dial on this
    /// rather than on the analysis mode, so a future model that emits real
    /// probabilities per frame lights the dial up without a UI change.
    var confidenceLevels: Int {
        var seen = [Bool](repeating: false, count: 256)
        var count = 0
        for pixel in pixels where !seen[Int(pixel)] {
            seen[Int(pixel)] = true
            count += 1
        }
        return count
    }

    /// True when thresholding this grid can change the result.
    var carriesConfidence: Bool { confidenceLevels > 2 }

    /// The complementary region's mask: `land = 1 − sky`, by construction.
    func inverted() -> SceneMask {
        SceneMask(
            region: region.complement, width: width, height: height,
            pixels: pixels.map { 255 - $0 }, geometry: geometry,
            provenance: provenance)
    }

    /// The grid as a Core Image mask.
    ///
    /// Linear gray on purpose: the bytes are probabilities, and a
    /// gamma-managed gray space would bend every mid-value on its way into
    /// the working space. Built through a `CGImage` so orientation is
    /// handled once by Core Image itself — the classic bottom-up flip bug
    /// lives in the raw-bitmap initializers, not this path.
    func ciImage() -> CIImage? {
        guard width > 0, height > 0, pixels.count == width * height,
              let data = CFDataCreate(nil, pixels, pixels.count),
              let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.linearGray),
              let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)
        else { return nil }
        return CIImage(cgImage: cgImage)
    }
}

/// The experiment's dials. Post-processing values live OUTSIDE every cache
/// key — masks are cached raw, so these iterate live without re-inference.
struct SegmentationSettings: Codable, Equatable, Sendable {
    /// Confidence floor: a cell counts as the region above this.
    var threshold: Double = 0.5
    /// Gaussian feather radius, in mask-grid pixels.
    var featherRadius: Double = 2.5
    /// Boundary bias, in grid pixels, applied to the RESTORING region.
    ///
    /// Positive erodes it — less occlusion, letters sit further over the
    /// scene. Negative dilates it — more occlusion, letters tuck further
    /// behind. The spike defaulted this to 1.5 on the theory that letters
    /// sinking into a mis-detected boundary look worse than a sliver of
    /// scene failing to occlude them. Measured against a hand-drawn skyline
    /// (2026-08-31) that default cost 0.29 IoU points and pushed type over
    /// every roofline, so it is 0 now: trust the mask, and let the
    /// photographer bias it either way when the scene calls for it.
    var edgeBias: Double = 0
    /// Whether frames are analyzed per frame or as one sequence-level mask.
    var maskMode: MaskMode = .sequence

    enum MaskMode: String, Codable, Equatable, Sendable {
        /// One mask per frame — the drift-inspection mode.
        case perFrame
        /// One static mask voted across sampled frames — the default for an
        /// interval sequence, where the camera is locked off and what drifts
        /// frame to frame is the model's opinion, not the skyline.
        case sequence
    }
}

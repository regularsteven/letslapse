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
    /// Conservative erosion of the restoring region, in grid pixels. Bias
    /// always means LESS occlusion — letters sinking into a mis-detected
    /// boundary look broken; a sliver of scene not occluding them doesn't.
    var edgeBias: Double = 1.5
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

import CoreGraphics
import Foundation

// Turning a Lightroom sidecar into a LetsLapse grade.
//
// `LightroomSidecar` reads the file; this decides what the numbers MEAN here.
// The two are apart because the second is arguable and the first is not.
//
// Three kinds of field, and the difference matters more than the code:
//
//   EXACT     — same quantity, same units. Exposure is EV in both. A value
//               that transfers unchanged and renders the same amount of
//               brightening is exact whatever else differs.
//   SCALED    — same idea, different scale. Lightroom's ±100 sliders are our
//               ±1. The number transfers; whether +60 Shadows lifts the same
//               shadows depends on two different tone curves, and it will not
//               be identical.
//   LOST      — no control to put it in. Reported, never silently dropped.
//
// This type deliberately produces PLAIN VALUES — a field table, shapes,
// per-mask grades — rather than reaching into the app's `PhotoAdjustments`.
// The Kit cannot see that type, and keeping the mapping here is what lets
// `swift test` pin the arithmetic against the real sidecar.

/// A Lightroom sidecar expressed in LetsLapse's own vocabulary.
public struct LightroomImport: Equatable, Sendable {

    /// The whole-picture grade, keyed by `PhotoAdjustmentField`'s raw value so
    /// the app can write them straight through its own key paths without this
    /// file knowing the type. Engine units: EV for exposure, ±1 for the
    /// hundred-scale sliders, 0…1 for the unipolar ones.
    public var adjustments: [String: Double] = [:]

    /// The masks worth carrying, each with the grade applied through it.
    public var masks: [MaskedGrade] = []

    /// What did not survive, in the order it was found. Every line is
    /// something a person would notice if they compared the two pictures.
    public var unsupported: [String] = []

    /// What DID survive, for the same reason — an import that says only what
    /// it lost reads like a failure even when it carried nine tenths.
    public var applied: [String] = []

    public init() {}

    /// One imported mask: its shape, whether the grade lands inside or out,
    /// and the grade itself.
    public struct MaskedGrade: Equatable, Sendable {
        public var name: String
        public var shape: MaskShape
        /// True when the grade applies OUTSIDE the shape.
        public var inverted: Bool
        public var adjustments: [String: Double]

        public init(name: String, shape: MaskShape, inverted: Bool,
                    adjustments: [String: Double]) {
            self.name = name
            self.shape = shape
            self.inverted = inverted
            self.adjustments = adjustments
        }
    }

    // MARK: - The global map

    /// Lightroom's key, our field name, and the divisor that turns one into
    /// the other. A divisor of 1 is an EXACT transfer.
    private static let globals: [(crs: String, field: String, divisor: Double)] = [
        ("Exposure2012", "exposure", 1),          // EV in both
        ("Contrast2012", "contrast", 100),
        ("Highlights2012", "highlights", 100),
        ("Shadows2012", "shadows", 100),
        ("Whites2012", "whites", 100),
        ("Blacks2012", "blacks", 100),
        ("Vibrance", "vibrance", 100),
        ("Saturation", "saturation", 100),
        ("Clarity2012", "clarity", 100),
        ("Texture", "texture", 100),
        ("Sharpness", "sharpen", 100),
        ("SharpenEdgeMasking", "sharpenMasking", 100),
        ("LuminanceSmoothing", "noiseReduction", 100),
        ("ColorNoiseReduction", "colorNoiseReduction", 100),
        ("VignetteAmount", "vignetteIntensity", 100),
    ]

    /// The local (per-mask) map. Lightroom's local sliders are already
    /// normalised to ±1 in the file — `LocalExposure2012="0.5"` is half a
    /// slider, not half a stop — so they scale differently from the globals.
    private static let locals: [(crs: String, field: String, scale: Double)] = [
        // ±1 in the file, ±4 EV in Lightroom's UI. Ours travels ±2, and the
        // caller clamps; a local lift past two stops is a different picture.
        ("Exposure2012", "exposure", 4),
        ("Contrast2012", "contrast", 1),
        ("Highlights2012", "highlights", 1),
        ("Shadows2012", "shadows", 1),
        ("Clarity2012", "clarity", 1),
        ("Saturation", "saturation", 1),
        // Local Temperature is ±1 in the file and reads ±100 in the UI, where
        // full travel is roughly ±1000 K at daylight. Our masked Temp is a
        // mired offset with the same intent and the same reach, so ±1 maps
        // onto its ±25.
        ("Temperature", "temperature", 25),
        ("Tint", "tint", 1),
    ]

    /// Map a parsed sidecar.
    public static func map(_ sidecar: LightroomSidecar) -> LightroomImport {
        var out = LightroomImport()
        out.unsupported = sidecar.unsupported

        for entry in globals {
            guard let value = sidecar.double(entry.crs), value != 0 else { continue }
            out.adjustments[entry.field] = value / entry.divisor
            out.applied.append(
                entry.divisor == 1
                    ? "\(entry.crs) \(signed(value)) → \(entry.field) (exact)"
                    : "\(entry.crs) \(signed(value)) → \(entry.field) \(trimmed(value / entry.divisor))")
        }

        // White balance. "As Shot" is our default and needs saying only when
        // it is NOT that: a custom white in the sidecar is a Kelvin/Tint pair,
        // and ours is a mired/tint pair, so it transfers — but only for a file
        // whose as-shot our converter reads the same way Adobe's does, which
        // is a separate and unfinished argument (see RawDecodePath).
        if let balance = sidecar.whiteBalance, balance != "As Shot" {
            if let kelvin = sidecar.double("Temperature"), kelvin > 1000 {
                out.adjustments["whiteMired"] = 1_000_000 / kelvin
                out.adjustments["whiteTint"] = sidecar.double("Tint") ?? 0
                out.applied.append("White balance \(Int(kelvin)) K → owned white")
            } else {
                out.unsupported.append("White balance \u{201C}\(balance)\u{201D} — not carried")
            }
        }

        for correction in sidecar.corrections where correction.isActive && !correction.isNeutral {
            map(correction, into: &out)
        }
        return out
    }

    private static func map(_ correction: LightroomSidecar.Correction,
                            into out: inout LightroomImport) {
        // Only the masks whose SHAPE we can rebuild. An AI mask's geometry is
        // a bitmap in Adobe's own encoding, and a correction whose only mask
        // is one of those has nowhere to land — `unsupported` already says so.
        let usable = correction.masks.filter {
            $0.isActive && ($0.isRadialGradient || $0.isLinearGradient)
        }
        guard !usable.isEmpty else { return }

        var values: [String: Double] = [:]
        for entry in locals {
            guard let value = correction.double(entry.crs), value != 0 else { continue }
            values[entry.field] = value * entry.scale * correction.amount
        }
        guard !values.isEmpty else { return }

        // Anything the correction sets that we have no local control for.
        let known = Set(locals.map(\.crs))
        for (key, raw) in correction.locals
        where !known.contains(key) && (Double(raw.replacingOccurrences(of: "+", with: "")) ?? 0) != 0 {
            out.unsupported.append(
                "Mask \u{201C}\(correction.name)\u{201D} · Local\(key) — no equivalent control")
        }

        for mask in usable {
            guard let shape = shape(from: mask) else { continue }
            // Roundness morphs the ellipse toward a rounded rectangle. At 0 it
            // IS an ellipse, which is the only case a MaskShape can draw.
            if let roundness = mask.double("Roundness"), roundness != 0 {
                out.unsupported.append(
                    "Mask \u{201C}\(mask.name)\u{201D} · Roundness \(Int(roundness)) — drawn as a plain ellipse")
            }
            out.masks.append(MaskedGrade(
                name: mask.name.isEmpty ? correction.name : mask.name,
                shape: shape,
                inverted: appliesOutside(mask),
                adjustments: values))
            out.applied.append(
                "Mask \u{201C}\(mask.name)\u{201D} (\(mask.kind)) → \(shape.kind.displayName)")
        }
    }

    // MARK: - Geometry

    /// A Lightroom gradient mask as a `MaskShape`.
    ///
    /// Adobe stores a radial as the BOUNDING BOX of its ellipse — Top/Left/
    /// Bottom/Right as fractions of the image, x against width and y against
    /// height, and free to fall outside 0…1 when the ellipse runs off the
    /// frame. That is the same normalisation `MaskShape` uses, so the centre
    /// and the two radii come straight out of it.
    public static func shape(from mask: LightroomSidecar.Mask) -> MaskShape? {
        if mask.isRadialGradient {
            guard let top = mask.double("Top"), let left = mask.double("Left"),
                  let bottom = mask.double("Bottom"), let right = mask.double("Right")
            else { return nil }
            let shape = MaskShape(
                kind: .radial,
                center: CGPoint(x: (left + right) / 2, y: (top + bottom) / 2),
                radiusX: abs(right - left) / 2,
                radiusY: abs(bottom - top) / 2,
                rotationDegrees: MaskShape.foldedAngle(mask.double("Angle") ?? 0),
                // Lightroom's Feather is 0…100 over the same span ours is a
                // fraction of. The FALLOFF differs — theirs is a smooth curve,
                // ours is linear across the band — so this is the right amount
                // of softness with a slightly different shoulder.
                feather: min(max((mask.double("Feather") ?? 50) / 100, 0), 1))
            return shape
        }
        if mask.isLinearGradient {
            // A linear gradient is two points: the full end and the zero end.
            guard let x1 = mask.double("ZeroX"), let y1 = mask.double("ZeroY"),
                  let x2 = mask.double("FullX"), let y2 = mask.double("FullY")
            else { return nil }
            // Ours runs full → zero, Adobe's names the zero end first.
            return MaskShape.linear(
                from: CGPoint(x: x2, y: y2), to: CGPoint(x: x1, y: y1), feather: 1)
        }
        return nil
    }

    /// Whether the grade lands OUTSIDE the shape.
    ///
    /// Two flags decide it and they compose. A radial gradient's historic
    /// default applied the effect outside the circle; `Flipped` is the newer
    /// schema's record of it having been turned inside, and `MaskInverted` is
    /// the user's own invert on top. So the effect is inside when exactly one
    /// of them says so.
    ///
    /// **This is the one mapping in the file that is inferred rather than
    /// documented**, and it is the one a reference render settles first: get
    /// it backwards and the grade lands on precisely the wrong pixels. It is
    /// one function so it is one line to correct.
    public static func appliesOutside(_ mask: LightroomSidecar.Mask) -> Bool {
        guard mask.isRadialGradient else { return mask.isInverted }
        let flipped = mask.bool("Flipped") ?? false
        return !(flipped != mask.isInverted)
    }

    // MARK: - Formatting

    private static func signed(_ value: Double) -> String {
        value == 0 ? "0" : String(format: "%+.2f", value)
    }

    private static func trimmed(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

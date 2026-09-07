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

    /// The calibration applied on the way in — see `LightroomImport.calibration`.
    public var calibrationID: String = ""

    /// What DID survive, for the same reason — an import that says only what
    /// it lost reads like a failure even when it carried nine tenths.
    public var applied: [String] = []

    public init() {}

    /// One imported mask: what it selects, whether the grade lands inside or
    /// out, and the grade itself.
    public struct MaskedGrade: Equatable, Sendable {

        /// What the grade is applied through.
        public enum Target: Equatable, Sendable {
            /// A shape rebuilt from Adobe's own parameters — the same
            /// ellipse or gradient, to the pixel.
            case shape(MaskShape)
            /// One of OUR semantic regions, named as `MaskRef` spells it.
            ///
            /// This is the substitution that lets an AI mask arrive at all.
            /// Adobe stores its sky as a bitmap we cannot read (see
            /// `skySubstitutionNote`), but "the sky" is not Adobe's idea —
            /// it is a fact about the photograph, and this app segments it
            /// too. So the CORRECTION transfers exactly and the BOUNDARY is
            /// ours. For a timelapse that is arguably the better of the two:
            /// a bitmap is one frame's answer, and ours re-segments per seam.
            case semantic(String)
        }

        public var name: String
        public var target: Target
        /// True when the grade applies OUTSIDE the mask.
        public var inverted: Bool
        public var adjustments: [String: Double]

        /// The rebuilt shape, for the parametric masks.
        public var shape: MaskShape? {
            if case .shape(let shape) = target { return shape }
            return nil
        }

        public init(name: String, target: Target, inverted: Bool,
                    adjustments: [String: Double]) {
            self.name = name
            self.target = target
            self.inverted = inverted
            self.adjustments = adjustments
        }
    }

    /// Said in the import report wherever a sky is substituted, because the
    /// difference is real and the photographer should hear it from us rather
    /// than notice it later.
    public static let skySubstitutionNote =
        "the boundary is this app's own sky segmentation, not Adobe's"

    /// Lightroom's named white-balance presets and the Kelvin they
    /// conventionally mean. Approximate by construction: Lightroom resolves a
    /// preset against the camera's own profile, so "Cloudy" is not exactly
    /// 6500 K on every body. Closer than nothing, and reported as approximate.
    static let namedIlluminants: [String: Double] = [
        "Daylight": 5500, "Cloudy": 6500, "Shade": 7500,
        "Tungsten": 2850, "Fluorescent": 3800, "Flash": 5500,
    ]

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

    /// The correction that makes an imported grade land where Lightroom put
    /// it, rather than where our engine would put the same numbers.
    ///
    /// **WHY THIS IS IN THE IMPORT AND NOT IN THE RENDERER.** The bench found
    /// it as a render axis, because that was the quick way to measure it: our
    /// renders came out +0.27 to +0.87 stops bright on every file and every
    /// variant, and our shadows lifted further than Lightroom's. But it is a
    /// correction of ONE RENDERER AGAINST ANOTHER, and the only place that
    /// comparison means anything is an imported Lightroom edit.
    ///
    /// Putting it in the engine instead would darken every LetsLapse project
    /// ever shot by half a stop to match a program the photographer may not
    /// own. Our native look is our own. So it lives here, on the way in, and
    /// touches nothing else.
    ///
    /// Versioned because it is fitted, not derived: `docs/render-variants/`
    /// records which corpus produced it, and a future fit gets the next id
    /// rather than silently replacing this one.
    public struct Calibration: Equatable, Sendable {
        public let id: String
        /// Added to the sidecar's exposure, in EV.
        public let exposureOffsetEV: Double
        /// Multiplies the sidecar's Shadows.
        public let shadowsScale: Double
        public let note: String
    }

    /// Fitted on `batch1` (five Sony A7 IV frames, Lightroom 17.5),
    /// 2026-09-07. Took the corpus from mean ΔE2000 12.76 to 7.46.
    public static let calibration = Calibration(
        id: "cal1",
        exposureOffsetEV: -0.47,
        shadowsScale: 0.7,
        note: """
            fitted on batch1, 5 frames, Sony ILCE-7M4, Lightroom 17.5. \
            Dehaze is NOT here: the measurement says ours is about half \
            Adobe's strength, but there is no dehaze control on \
            PhotoAdjustments to import one into yet, so it stays a render \
            axis (see docs/TODO.md).
            """)

    /// Map a parsed sidecar.
    public static func map(_ sidecar: LightroomSidecar) -> LightroomImport {
        var out = LightroomImport()
        out.unsupported = sidecar.unsupported
        out.calibrationID = calibration.id

        for entry in globals {
            guard let value = sidecar.double(entry.crs), value != 0 else { continue }
            out.adjustments[entry.field] = value / entry.divisor
            if entry.field == "shadows" {
                out.adjustments[entry.field] = value / entry.divisor * calibration.shadowsScale
            }
            out.applied.append(
                entry.divisor == 1
                    ? "\(entry.crs) \(signed(value)) → \(entry.field) (exact)"
                    : "\(entry.crs) \(signed(value)) → \(entry.field) \(trimmed(value / entry.divisor))")
        }

        // The exposure trim. Applied whether or not the sidecar moved
        // exposure: it corrects a difference between two renderers' baselines,
        // which is there at +0.00 EV as much as at +0.29.
        let exposure = (out.adjustments["exposure"] ?? 0) + calibration.exposureOffsetEV
        out.adjustments["exposure"] = exposure
        out.applied.append(String(
            format: "Calibration %@ — exposure %+.2f EV, shadows ×%.2f",
            calibration.id, calibration.exposureOffsetEV, calibration.shadowsScale))

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
            } else if let kelvin = namedIlluminants[balance] {
                // A named preset carries no Kelvin: Lightroom resolves it per
                // camera from the profile's calibration, which we cannot
                // reproduce. These are the conventional values, and they are
                // much closer than dropping the white entirely.
                out.adjustments["whiteMired"] = 1_000_000 / kelvin
                out.adjustments["whiteTint"] = sidecar.double("Tint") ?? 0
                out.applied.append(
                    "White balance \u{201C}\(balance)\u{201D} → \(Int(kelvin)) K "
                    + "(conventional value; Lightroom resolves it per camera)")
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
        // The masks we can land somewhere: the parametric ones, whose shape we
        // rebuild exactly, and a SKY, which we substitute our own
        // segmentation for. Everything else — subject, background, object,
        // brush, range — has no geometry we can reconstruct.
        let usable = correction.masks.filter {
            $0.isActive && ($0.isRadialGradient || $0.isLinearGradient || isSky($0))
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
            if isSky(mask) {
                out.masks.append(MaskedGrade(
                    name: mask.name.isEmpty ? "Sky" : mask.name,
                    target: .semantic("sky"), inverted: mask.isInverted,
                    adjustments: values))
                out.applied.append(
                    "Mask \u{201C}\(mask.name)\u{201D} (AI sky) → this app\u{2019}s Sky region — "
                    + skySubstitutionNote)
                continue
            }
            guard let shape = shape(from: mask) else { continue }
            // Roundness morphs the ellipse toward a rounded rectangle. At 0 it
            // IS an ellipse, which is the only case a MaskShape can draw.
            if let roundness = mask.double("Roundness"), roundness != 0 {
                out.unsupported.append(
                    "Mask \u{201C}\(mask.name)\u{201D} · Roundness \(Int(roundness)) — drawn as a plain ellipse")
            }
            out.masks.append(MaskedGrade(
                name: mask.name.isEmpty ? correction.name : mask.name,
                target: .shape(shape),
                inverted: appliesOutside(mask),
                adjustments: values))
            out.applied.append(
                "Mask \u{201C}\(mask.name)\u{201D} (\(mask.kind)) → \(shape.kind.displayName)")
        }
    }

    /// Whether an AI mask is a SKY — the one semantic region this app also
    /// knows, and therefore the one that can be substituted rather than
    /// dropped.
    ///
    /// Adobe's `MaskSubType` 2 is the sky in every file seen so far, and
    /// Lightroom names them "Sky 1", "Sky 2"… The subtype is the stronger
    /// signal so it decides on its own; the name is a fallback for a file that
    /// omits it, checked case-insensitively because a photographer may rename
    /// a mask.
    public static func isSky(_ mask: LightroomSidecar.Mask) -> Bool {
        guard mask.isImage else { return false }
        if mask.attributes["MaskSubType"] == "2" { return true }
        return mask.name.lowercased().hasPrefix("sky")
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

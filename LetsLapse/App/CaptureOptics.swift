import Foundation

/// One lens chip the Capture Optics model offers on this hardware.
/// `displayFactor` is the user-facing number (1×, 2×, 5×); `rawFactor` is the
/// same stop in the capture device's own zoom-factor space (on virtual
/// devices, factors are relative to the *widest* constituent, so display 1×
/// is raw 2.0 on a triple camera — the classic factor-space trap).
/// Spec: docs/capture-optics-spec.md; validated on hardware 2026-08-04.
struct DerivedOpticsStop: Identifiable, Equatable, Hashable {
    enum Kind: String {
        /// A physical lens at its native focal length.
        case optical = "optical"
        /// The sensor's own native crop (quad-Bayer binning) — full quality,
        /// no upscaling. Read from `secondaryNativeResolutionZoomFactors`.
        case sensorCrop = "sensor-crop"
        /// A plain 2× digital crop-and-upscale of a native lens.
        case digital = "digital-2x"
    }

    var displayFactor: Double
    var rawFactor: Double
    var kind: Kind
    /// The constituent expected to back this stop (verified live by the probe).
    var expectedBacking: String

    var id: String { "\(kind.rawValue)-\(displayFactor)" }

    /// The chip text, matching the app's existing vocabulary: ".5×", "1×",
    /// "2×", "5×", "10×" — always formatted from the hardware-derived factor.
    var chipLabel: String {
        if displayFactor < 1 {
            let text = String(format: "%.1f", displayFactor)
            return (text.hasPrefix("0") ? String(text.dropFirst()) : text) + "×"
        }
        return String(format: "%g×", displayFactor)
    }
}

/// The derivation rule from the Capture Optics spec, as a pure function so
/// the on-device probe report *is* the rule running against real hardware:
///
/// 1. Native stops always: the widest constituent plus one stop per
///    switchover crossing.
/// 2. Sensor-crop stops: every native crop factor the formats advertise.
/// 3. Digital 2× stops: for each native stop at display ≥ 1×, its double —
///    the ultra-wide is never doubled (display < 1 excludes it), and any
///    candidate within 5% of an existing stop is dropped as a duplicate
///    (which is how 2×-of-1× yields to the sensor crop when one exists).
enum CaptureOpticsDerivation {
    struct Input {
        /// Widest-first constituent device type names ("wide" fallback for a
        /// single physical camera).
        var constituents: [String]
        /// Raw zoom factors at which the device switches constituents
        /// (empty for a physical device).
        var switchOverFactors: [Double]
        /// Union of `secondaryNativeResolutionZoomFactors` across formats,
        /// in raw factor space.
        var sensorCropFactors: [Double]
        /// The active format's ceiling; digital stops must stay below it.
        var maxZoomFactor: Double
    }

    static func derive(_ input: Input) -> [DerivedOpticsStop] {
        // Display divisor: the raw factor at which the main wide camera is
        // primary. 1.0 when the widest constituent IS the wide (single/dual
        // wide-tele layouts); the first switchover when an ultra-wide sits
        // in front of it.
        let wideIndex = input.constituents.firstIndex { $0.contains("WideAngle") } ?? 0
        let divisor = wideIndex == 0 ? 1.0 : (input.switchOverFactors[safe: wideIndex - 1] ?? 1.0)

        var stops: [DerivedOpticsStop] = []
        let nativeRawFactors = [1.0] + input.switchOverFactors
        for (index, raw) in nativeRawFactors.enumerated() {
            stops.append(DerivedOpticsStop(
                displayFactor: raw / divisor,
                rawFactor: raw,
                kind: .optical,
                expectedBacking: input.constituents[safe: index] ?? input.constituents.last ?? "?"))
        }

        func existing(near display: Double) -> Bool {
            stops.contains { abs($0.displayFactor - display) / display < 0.05 }
        }
        func backing(forRaw raw: Double) -> String {
            var index = 0
            for (i, factor) in input.switchOverFactors.enumerated() where raw >= factor {
                index = i + 1
            }
            return input.constituents[safe: index] ?? "?"
        }

        for raw in input.sensorCropFactors.sorted() where !existing(near: raw / divisor) {
            stops.append(DerivedOpticsStop(
                displayFactor: raw / divisor,
                rawFactor: raw,
                kind: .sensorCrop,
                expectedBacking: backing(forRaw: raw)))
        }

        for stop in stops where stop.kind == .optical && stop.displayFactor >= 1.0 {
            let display = stop.displayFactor * 2
            let raw = stop.rawFactor * 2
            guard !existing(near: display), raw <= input.maxZoomFactor else { continue }
            stops.append(DerivedOpticsStop(
                displayFactor: display,
                rawFactor: raw,
                kind: .digital,
                expectedBacking: backing(forRaw: raw)))
        }

        return stops.sorted { $0.displayFactor < $1.displayFactor }
    }
}

/// User-facing Capture Optics preferences. Enhanced (non-optical) stops ship
/// enabled — matching native Camera on Pro iPhones and Indigo on iPad — and
/// Settings → Recording lets the user hide them. Optical stops always show.
enum CaptureOpticsStore {
    static let enhancedLensesKey = "letslapse.captureOptics.enhancedLenses"

    static var enhancedLensesEnabled: Bool {
        UserDefaults.standard.object(forKey: enhancedLensesKey) as? Bool ?? true
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

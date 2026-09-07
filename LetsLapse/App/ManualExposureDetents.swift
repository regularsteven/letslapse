import Foundation

/// The third-stop detent lists Photo mode's manual-exposure wheels (SHUTTER,
/// ISO) scroll through, plus the shared `A` (auto) sentinel index both
/// wheels use at their low end. Values and full-stop spacing are the
/// "Photo mode · Manual exposure" design handoff's locked-in list — do not
/// resnap without checking that spec.
enum ManualExposureDetents {
    /// Both wheels reserve this index for "hand this parameter back to AE."
    static let auto = -1

    static let shutterSeconds: [Double] = [
        1.0 / 8000, 1.0 / 6400, 1.0 / 5000, 1.0 / 4000, 1.0 / 3200,
        1.0 / 2500, 1.0 / 2000, 1.0 / 1600, 1.0 / 1250, 1.0 / 1000,
        1.0 / 800, 1.0 / 640, 1.0 / 500, 1.0 / 400, 1.0 / 320,
        1.0 / 250, 1.0 / 200, 1.0 / 160, 1.0 / 125, 1.0 / 100,
        1.0 / 80, 1.0 / 60, 1.0 / 50, 1.0 / 40, 1.0 / 30,
        1.0 / 25, 1.0 / 20, 1.0 / 15, 1.0 / 13, 1.0 / 10,
        1.0 / 8, 1.0 / 6, 1.0 / 5, 1.0 / 4, 0.3,
        0.4, 0.5, 0.6, 0.8, 1.0,
    ]

    static let iso: [Float] = [
        32, 40, 50, 64, 80, 100, 125, 160, 200, 250,
        320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500,
        3200, 4000, 5000, 6400,
    ]

    /// Every 3rd shutter detent starting at the fast end is a labelled full
    /// stop; the rest are unlabelled third-stops.
    static func isFullStopShutter(_ index: Int) -> Bool { index >= 0 && index % 3 == 0 }

    /// ISO's full stops land on the same rhythm, offset by 2 (50, 100, 200…).
    static func isFullStopISO(_ index: Int) -> Bool { index >= 0 && index % 3 == 2 }

    /// `1/N` below 1 s, `N.Ns` at/above — the app's one shutter-speed label
    /// format, shared by the exposure-lock readout and the manual wheels.
    static func shutterLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    /// Nearest detent index to an arbitrary shutter duration — how entering
    /// manual seeds the wheel from whatever AE currently reads, clamped to
    /// the list's own ends (the device's live range may be narrower still;
    /// callers additionally clamp to the active format before writing).
    static func nearestShutterIndex(to seconds: Double) -> Int {
        nearestIndex(to: log2(max(seconds, 1e-6)), in: shutterSeconds.map { log2(max($0, 1e-6)) })
    }

    /// Nearest detent index to an arbitrary ISO value, compared in stops
    /// (log2) so the "nearest" match is perceptually even across the range.
    static func nearestISOIndex(to value: Float) -> Int {
        nearestIndex(to: log2(Double(max(value, 1))), in: iso.map { log2(Double(max($0, 1))) })
    }

    /// Which shutter detents the active format can actually reach, so the
    /// wheel can stop a drag at the device's real envelope instead of
    /// silently clamping the write underneath a value the UI still shows as
    /// selected.
    static func reachableShutterIndices(within range: ClosedRange<Double>) -> ClosedRange<Int> {
        let indices = shutterSeconds.indices.filter { range.contains(shutterSeconds[$0]) }
        guard let lo = indices.first, let hi = indices.last else { return 0...(shutterSeconds.count - 1) }
        return lo...hi
    }

    /// The ISO equivalent of `reachableShutterIndices`.
    static func reachableISOIndices(within range: ClosedRange<Float>) -> ClosedRange<Int> {
        let indices = iso.indices.filter { range.contains(iso[$0]) }
        guard let lo = indices.first, let hi = indices.last else { return 0...(iso.count - 1) }
        return lo...hi
    }

    private static func nearestIndex(to target: Double, in values: [Double]) -> Int {
        guard !values.isEmpty else { return 0 }
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, value) in values.enumerated() {
            let distance = abs(value - target)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}

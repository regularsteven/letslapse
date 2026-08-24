import Foundation
import CoreVideo

/// Catches a frame whose framing has physically moved before it is averaged
/// into a stacked window, where it would ghost the output.
///
/// Why this exists: on 2026-08-23 an iPhone 12 Pro shoot at thermal `critical`
/// produced windows in which the lens suspension sagged ~63 px along gravity
/// for a second or two and snapped back (OIS servo dropout). The engine's own
/// records were spotless — the event happens below the app — so the only
/// defence is to look at the pixels. One displaced frame in an ~85-frame stack
/// doubles every edge in the output; a whole displaced window jumps the shot.
///
/// How: each BGRA frame is reduced to row and column luma projections on a
/// strided single pass (~190k pixel reads at 12 MP — well under a millisecond,
/// no GPU), high-passed, and correlated against a rolling run anchor at
/// integer lags. A frame is rejected only on a *confident, large* translation;
/// low confidence — kinetic scenes, flat scenes, torn readouts — always
/// accepts, so the gate can starve nothing it doesn't understand.
///
/// The anchor rolls: it refreshes from the last accepted frame whenever a
/// window closes with its accepted frames near baseline (absorbing slow OIS
/// wander, which is real and harmless), and if nearly everything in two
/// consecutive windows is displaced the same way, the world has genuinely
/// changed — the gate re-anchors there and reports it, rather than rejecting
/// the rest of the shoot.
///
/// Translation-only by design. It cannot see rotation or zoom; it doesn't
/// need to — the failure it guards against is a shift an order of magnitude
/// above its threshold.
///
/// Not thread-safe; drive it from the capture path's serial queue.
public final class FrameAlignmentGate {

    /// The gate's reading of one frame. `measured` is false when the frame
    /// could not be judged (first frame of the run, non-BGRA, or a scene too
    /// flat/kinetic to correlate) — such frames are always accepted.
    public struct Verdict {
        public let accepted: Bool
        public let measured: Bool
        /// Estimated translation against the run anchor, full-resolution
        /// pixels, sub-sample refined. Positive dy = content moved down.
        public let dxPixels: Double
        public let dyPixels: Double
        /// Worst-axis correlation confidence (0…1) behind the estimate.
        public let confidence: Double

        public var shiftMagnitudePixels: Double {
            (dxPixels * dxPixels + dyPixels * dyPixels).squareRoot()
        }
    }

    /// One window's tally, returned (and reset) at each window boundary.
    public struct WindowSummary {
        /// Frames the gate could actually judge.
        public let measuredFrames: Int
        /// Reject verdicts issued. The caller may still have used such a
        /// frame (a single-frame window keeps its only frame rather than
        /// starve) — blend depth tells the two apart in the log.
        public let rejectedFrames: Int
        /// Largest measured shift this window, accepted frames included.
        public let peakShiftPixels: Double?
        /// The gate adopted the displaced framing as the new baseline —
        /// two consecutive windows were mostly displaced the same way, so
        /// this is a real reframe (knocked tripod), not a glitch.
        public let reanchored: Bool
    }

    private struct Profiles {
        var rows: [Float]
        var cols: [Float]
    }

    private let rejectThresholdPixels: Double
    private let searchRadiusPixels: Double
    private let stride: Int
    /// A confident verdict needs at least this correlation on both axes.
    private let confidenceFloor = 0.5
    /// Moving-average radius of the high-pass, in samples. Also the number of
    /// samples trimmed from each profile end before correlating: the filter's
    /// edge windows are asymmetric, so the first/last `radius` samples of a
    /// shifted profile are not the shifted samples of the original — left in,
    /// they bias the peak (measured: a synthetic +64 px shift read as +49).
    private let highPassRadius = 8
    /// High-passed profiles need at least this variance to be worth
    /// correlating — below it the scene is featureless along that axis.
    private let varianceFloor: Float = 0.25
    /// Accepted-median shift below this refreshes the anchor (drift absorb).
    private let anchorRefreshLimitPixels = 4.0

    private var anchor: Profiles?
    private var lastProfiles: Profiles?
    private var lastAcceptedProfiles: Profiles?

    // Per-window tallies, reset by `windowClosed`.
    private var measuredThisWindow = 0
    private var rejectedThisWindow = 0
    private var peakShiftThisWindow: Double?
    private var acceptedShiftsThisWindow: [Double] = []
    /// Consecutive windows in which most measured frames were displaced.
    private var displacedWindows = 0

    public init(
        rejectThresholdPixels: Double = 12,
        searchRadiusPixels: Double = 96,
        sampleStride: Int = 8
    ) {
        self.rejectThresholdPixels = rejectThresholdPixels
        self.searchRadiusPixels = searchRadiusPixels
        self.stride = max(1, sampleStride)
    }

    // MARK: Per-frame

    public func evaluate(_ buffer: CVPixelBuffer) -> Verdict {
        guard let profiles = Self.projectionProfiles(of: buffer, stride: stride) else {
            return Verdict(accepted: true, measured: false, dxPixels: 0, dyPixels: 0, confidence: 0)
        }
        lastProfiles = profiles
        guard let anchor else {
            self.anchor = profiles
            lastAcceptedProfiles = profiles
            return Verdict(accepted: true, measured: false, dxPixels: 0, dyPixels: 0, confidence: 0)
        }
        let maxLag = max(1, Int((searchRadiusPixels / Double(stride)).rounded()))
        guard anchor.rows.count == profiles.rows.count,
              anchor.cols.count == profiles.cols.count,
              let vertical = Self.bestShift(
                  anchor: anchor.rows, current: profiles.rows,
                  maxLag: maxLag, edgeTrim: highPassRadius, varianceFloor: varianceFloor),
              let horizontal = Self.bestShift(
                  anchor: anchor.cols, current: profiles.cols,
                  maxLag: maxLag, edgeTrim: highPassRadius, varianceFloor: varianceFloor) else {
            return Verdict(accepted: true, measured: false, dxPixels: 0, dyPixels: 0, confidence: 0)
        }
        let dx = horizontal.lagSamples * Double(stride)
        let dy = vertical.lagSamples * Double(stride)
        let confidence = Double(min(vertical.confidence, horizontal.confidence))
        let magnitude = (dx * dx + dy * dy).squareRoot()

        measuredThisWindow += 1
        peakShiftThisWindow = max(peakShiftThisWindow ?? 0, magnitude)

        let displaced = confidence >= confidenceFloor && magnitude >= rejectThresholdPixels
        if displaced {
            rejectedThisWindow += 1
        } else {
            acceptedShiftsThisWindow.append(magnitude)
            lastAcceptedProfiles = profiles
        }
        return Verdict(
            accepted: !displaced, measured: true,
            dxPixels: dx, dyPixels: dy, confidence: confidence)
    }

    // MARK: Per-window

    public func windowClosed() -> WindowSummary {
        var reanchored = false
        let rejectedFraction = measuredThisWindow > 0
            ? Double(rejectedThisWindow) / Double(measuredThisWindow) : 0

        if measuredThisWindow > 0, rejectedFraction >= 0.6 {
            displacedWindows += 1
            if displacedWindows >= 2, let current = lastProfiles {
                anchor = current
                lastAcceptedProfiles = current
                displacedWindows = 0
                reanchored = true
            }
        } else {
            displacedWindows = 0
            // Baseline window: let the anchor follow slow, legitimate wander
            // (OIS drifts a pixel or two over minutes on a tripod) so the
            // threshold is always measured against the present, not the
            // framing at second zero.
            let sorted = acceptedShiftsThisWindow.sorted()
            if !sorted.isEmpty, sorted[sorted.count / 2] < anchorRefreshLimitPixels,
               let accepted = lastAcceptedProfiles {
                anchor = accepted
            }
        }

        let summary = WindowSummary(
            measuredFrames: measuredThisWindow,
            rejectedFrames: rejectedThisWindow,
            peakShiftPixels: peakShiftThisWindow,
            reanchored: reanchored)
        measuredThisWindow = 0
        rejectedThisWindow = 0
        peakShiftThisWindow = nil
        acceptedShiftsThisWindow.removeAll(keepingCapacity: true)
        return summary
    }

    // MARK: Profiles

    /// Row and column luma projections from one strided pass. Gamma-encoded
    /// integer luma is fine here — correlation only needs the shapes to
    /// match, not the photometry. BGRA only (the live-blend tap's format);
    /// anything else returns nil and the frame passes unjudged.
    private static func projectionProfiles(of buffer: CVPixelBuffer, stride: Int) -> Profiles? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let sampledColumns = width / stride
        let sampledRows = height / stride
        guard sampledColumns > 8, sampledRows > 8 else { return nil }

        var rowSums = [Float](repeating: 0, count: sampledRows)
        var colSums = [Float](repeating: 0, count: sampledColumns)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for rowIndex in 0..<sampledRows {
            let row = pixels + rowIndex * stride * bytesPerRow
            var rowSum: Int = 0
            for colIndex in 0..<sampledColumns {
                let p = row + colIndex * stride * 4
                // 77/150/29 ≈ Rec.601 in /256 fixed point.
                let luma = 77 * Int(p[2]) + 150 * Int(p[1]) + 29 * Int(p[0])
                rowSum += luma
                colSums[colIndex] += Float(luma)
            }
            rowSums[rowIndex] = Float(rowSum) / Float(sampledColumns * 256)
        }
        let rowCount = Float(sampledRows * 256)
        for index in colSums.indices { colSums[index] /= rowCount }

        return Profiles(rows: highPassed(rowSums), cols: highPassed(colSums))
    }

    /// Subtracts a ±8-sample moving average, so exposure and slow vignette /
    /// lighting changes between frames don't masquerade as displacement.
    private static func highPassed(_ profile: [Float], radius: Int = 8) -> [Float] {
        let count = profile.count
        guard count > radius * 2 + 1 else { return profile }
        var prefix = [Float](repeating: 0, count: count + 1)
        for index in 0..<count { prefix[index + 1] = prefix[index] + profile[index] }
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let low = max(0, index - radius)
            let high = min(count - 1, index + radius)
            let mean = (prefix[high + 1] - prefix[low]) / Float(high - low + 1)
            result[index] = profile[index] - mean
        }
        return result
    }

    // MARK: Correlation

    /// The lag (in samples) that best aligns `current` to `anchor`, by
    /// normalized cross-correlation over the overlap of the profiles'
    /// interiors (`edgeTrim` samples dropped from each end — see
    /// `highPassRadius`), parabolically refined between integer lags. nil
    /// when either profile is too flat to judge.
    private static func bestShift(
        anchor: [Float], current: [Float], maxLag: Int, edgeTrim: Int, varianceFloor: Float
    ) -> (lagSamples: Double, confidence: Float)? {
        let count = anchor.count
        guard count > maxLag * 4 + edgeTrim * 2 else { return nil }
        guard variance(of: anchor) > varianceFloor,
              variance(of: current) > varianceFloor else { return nil }

        var correlations = [Float](repeating: -1, count: maxLag * 2 + 1)
        var bestIndex = maxLag
        var bestValue: Float = -1
        for lag in -maxLag...maxLag {
            let start = max(edgeTrim, edgeTrim - lag)
            let end = min(count - edgeTrim, count - edgeTrim - lag)
            guard end - start > maxLag * 2 else { continue }
            var sumA: Float = 0, sumC: Float = 0, sumAA: Float = 0, sumCC: Float = 0, sumAC: Float = 0
            for index in start..<end {
                let a = anchor[index]
                let c = current[index + lag]
                sumA += a; sumC += c
                sumAA += a * a; sumCC += c * c; sumAC += a * c
            }
            let n = Float(end - start)
            let covariance = sumAC - sumA * sumC / n
            let varA = sumAA - sumA * sumA / n
            let varC = sumCC - sumC * sumC / n
            guard varA > 0, varC > 0 else { continue }
            let r = covariance / (varA * varC).squareRoot()
            correlations[lag + maxLag] = r
            if r > bestValue {
                bestValue = r
                bestIndex = lag + maxLag
            }
        }
        guard bestValue > 0 else { return nil }

        // Parabolic sub-sample refinement between the neighbouring lags.
        var refined = Double(bestIndex - maxLag)
        if bestIndex > 0, bestIndex < correlations.count - 1 {
            let left = Double(correlations[bestIndex - 1])
            let mid = Double(correlations[bestIndex])
            let right = Double(correlations[bestIndex + 1])
            let denominator = left - 2 * mid + right
            if denominator < 0 {
                let delta = 0.5 * (left - right) / denominator
                if abs(delta) <= 1 { refined += delta }
            }
        }
        return (refined, max(0, bestValue))
    }

    private static func variance(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        let sum = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
        return sum / Float(values.count)
    }
}

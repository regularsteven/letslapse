import Foundation
import AVFoundation
import CoreMedia

/// Eases a burst clip into and out of slow motion instead of cutting to it.
///
/// A video shoot records its burst at a higher rate than the rest of the run,
/// and the blend writes those frames out one-for-one at the project's output
/// rate — so by the time the segments reach the stitch, the burst clip is
/// *already* slow motion. Its neighbours are not, and the joins read as two
/// hard cuts.
///
/// This puts a cubic ease on both ends of that clip: the head is played back at
/// real time and eased down to the clip's own slow-motion rate, the tail eases
/// back up. Nothing outside the burst clip is touched, no pixels are rewritten,
/// and nothing is re-encoded beyond the stitch export that was already
/// happening — the whole effect is `scaleTimeRange` on the composition track.
///
/// The curve is the standard smoothstep `f(t) = 3t² − 2t³`, sampled as
/// `curveSegments` constant-speed steps per ramp because AVFoundation scales
/// whole time ranges, not continuous functions.
enum BurstRamp {

    // MARK: - Values

    /// Picker granularity, in seconds.
    static let step = 0.25
    /// The longest ramp either picker offers.
    static let maxDuration = 2.0
    /// Below this a ramp is three frames of output and imperceptible, so a clip
    /// too short to carry one gets no ramp rather than a token one.
    static let minimumDuration = 0.1

    /// Every ramp length the pickers offer. "Off" (app settings) and "Use
    /// default" (per project) are separate cases the views add themselves.
    static let choices: [Double] = stride(from: step, through: maxDuration + 0.001, by: step)
        .map { ($0 * 100).rounded() / 100 }

    /// "Off" / "0.25s" / "1s" — the picker's own values, which are always
    /// exact multiples of `step`.
    static func label(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Off" }
        return "\(String(format: "%g", seconds))s"
    }

    /// "0.62s" — a computed length (a capped ramp), rounded for display.
    static func preciseLabel(_ seconds: Double) -> String {
        var text = String(format: "%.2f", seconds)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text)s"
    }

    // MARK: - Curve

    /// The curve, sampled as at most this many constant-speed steps per ramp.
    /// Forty is dense enough that the steps are invisible at playback and cheap
    /// enough that a composition with several bursts still assembles instantly.
    static let curveSegments = 40

    /// No step may be shorter than one frame of output — 1/24 s, the slowest
    /// rate the app offers, so a step is at least a frame at any of them.
    ///
    /// This is the difference between a ramp that exports and one that doesn't.
    /// Forty steps across a ramp the clip capped to a tenth of a second would
    /// be 2.5 ms each: far below a frame, invisible either way, and forty
    /// sub-frame segments in a composition track is exactly the shape
    /// `AVAssetExportSession` gives up on. Short ramps get proportionally
    /// fewer, larger steps instead — the curve looks identical.
    static let minimumStepDuration = 1.0 / 24.0

    /// How many steps a ramp of `duration` output seconds is sampled at.
    static func segmentCount(forRamp duration: Double) -> Int {
        let byLength = Int(duration / minimumStepDuration)
        return max(3, min(curveSegments, byLength))
    }

    /// Cubic ease `f(t) = 3t² − 2t³`: flat at both ends, so the ramp leaves
    /// real time and arrives at the slow-motion rate without a velocity kink.
    static func smoothstep(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// How much of the burst clip each step of a ramp-in consumes per second of
    /// output, from the head of the ramp to where it meets the steady middle.
    ///
    /// The clip already runs `slowFactor` times slower than real life, so
    /// holding playback at slowness σ means eating `slowFactor / σ` clip-seconds
    /// per output second: `slowFactor`× at the head (which *is* real time) and
    /// 1× at the far end, where the ramp hands over to the untouched middle.
    private static func clipCostPerStep(slowFactor: Double, steps: Int) -> [Double] {
        (0..<steps).map { index in
            let t = (Double(index) + 0.5) / Double(steps)
            let slowness = 1 + (slowFactor - 1) * smoothstep(t)
            return slowFactor / slowness
        }
    }

    // MARK: - Planning

    /// One constant-speed piece of the retimed clip, as cumulative offsets from
    /// the clip's start: `clipEnd` walks the footage, `outputEnd` walks the
    /// finished timeline. Offsets rather than durations, so a long chain of
    /// floating-point additions can't drift the clip's end away from its real
    /// one — every boundary is absolute.
    struct Step: Equatable {
        var clipEnd: Double
        var outputEnd: Double
        /// False for the steady middle, which plays at the clip's own rate and
        /// so needs no scaling at all.
        var isScaled: Bool
    }

    struct Plan: Equatable {
        /// What was asked for, before the clip's own length had a say.
        var requestedRamp: Double
        /// What actually fits — never longer than `requestedRamp`.
        var appliedRamp: Double
        var steps: [Step]

        var isCapped: Bool { appliedRamp < requestedRamp - 0.001 }
    }

    /// Clip seconds one ramp spends per second of ramp, for a given sampling.
    private static func costFactor(slowFactor: Double, steps: Int) -> Double {
        let costs = clipCostPerStep(slowFactor: slowFactor, steps: steps)
        return costs.reduce(0, +) / Double(steps)
    }

    /// The longest ramp a burst clip of `burstOutputDuration` can carry at each
    /// end, in output seconds, and the sampling it will be drawn at. Length 0
    /// means the clip gets no ramp and is left exactly as it was.
    ///
    /// - Parameters:
    ///   - requested: the ramp the project asked for.
    ///   - burstOutputDuration: the burst clip's length in the stitched
    ///     timeline, i.e. already stretched by the slow motion.
    ///   - slowFactor: how many times slower than real time that clip plays.
    private static func fit(
        requested: Double,
        burstOutputDuration: Double,
        slowFactor: Double
    ) -> (ramp: Double, steps: Int, costFactor: Double) {
        let none = (ramp: 0.0, steps: 0, costFactor: 1.0)
        guard requested > 0,
              burstOutputDuration.isFinite, burstOutputDuration > 0,
              slowFactor.isFinite, slowFactor > 1 else { return none }

        // Two clamps, and both matter. The first is the obvious one: two ramps
        // can't each be longer than half the clip. The second is why that isn't
        // enough — a ramp is faster than the clip it rides on, so a second of
        // ramp spends `costFactor` seconds of footage. Without it the pair
        // would run off the end of the burst and bleed into its neighbours,
        // which is exactly what this feature exists not to do.
        func clamped(_ costFactor: Double) -> Double {
            let halved = min(requested, burstOutputDuration / 2)
            return min(halved, burstOutputDuration / (2 * costFactor))
        }

        // Size the ramp at full density first, then re-sample: a ramp the clip
        // cut down to a fraction of a second gets fewer, larger steps, and the
        // cost of a step changes slightly with the sampling, so the clamp is
        // taken again against the density actually used. Everything downstream
        // reads the second answer.
        let firstPass = clamped(costFactor(slowFactor: slowFactor, steps: curveSegments))
        guard firstPass >= minimumDuration else { return none }

        let steps = segmentCount(forRamp: firstPass)
        let factor = costFactor(slowFactor: slowFactor, steps: steps)
        let ramp = clamped(factor)
        guard ramp >= minimumDuration else { return none }
        return (ramp, steps, factor)
    }

    /// The longest usable ramp for a burst clip, in output seconds; 0 when it
    /// can't carry one. This is what the New Version screen's "capped to…" note
    /// reports, so it has to agree with what `plan` will do.
    static func appliedRamp(
        requested: Double,
        burstOutputDuration: Double,
        slowFactor: Double
    ) -> Double {
        fit(requested: requested,
            burstOutputDuration: burstOutputDuration,
            slowFactor: slowFactor).ramp
    }

    /// The retiming for one burst clip, or nil when it gets none (no ramp
    /// asked for, the clip isn't slow motion, or it's too short to carry one).
    static func plan(
        requestedRamp: Double,
        burstOutputDuration: Double,
        slowFactor: Double
    ) -> Plan? {
        let fitted = fit(
            requested: requestedRamp,
            burstOutputDuration: burstOutputDuration,
            slowFactor: slowFactor)
        guard fitted.ramp > 0 else { return nil }

        let costs = clipCostPerStep(slowFactor: slowFactor, steps: fitted.steps)
        let stepOutput = fitted.ramp / Double(fitted.steps)

        var clipCursor = 0.0
        var outputCursor = 0.0
        var steps: [Step] = []
        steps.reserveCapacity(fitted.steps * 2 + 1)

        // Ramp in: real time easing down to the clip's own slow-motion rate.
        for cost in costs {
            clipCursor += stepOutput * cost
            outputCursor += stepOutput
            steps.append(Step(clipEnd: clipCursor, outputEnd: outputCursor, isScaled: true))
        }

        // Steady middle: whatever the two ramps didn't eat, left alone. The
        // clamp above guarantees this is never negative; it reaches exactly
        // zero on a clip that is all ramp.
        let middle = burstOutputDuration - 2 * fitted.ramp * fitted.costFactor
        if middle > 0 {
            clipCursor += middle
            outputCursor += middle
            steps.append(Step(clipEnd: clipCursor, outputEnd: outputCursor, isScaled: false))
        }

        // Ramp out: the same curve mirrored, slow motion back up to real time.
        for cost in costs.reversed() {
            clipCursor += stepOutput * cost
            outputCursor += stepOutput
            steps.append(Step(clipEnd: clipCursor, outputEnd: outputCursor, isScaled: true))
        }

        // The last boundary IS the end of the clip. `apply` pins it to the
        // clip's real CMTime rather than trusting this number, but keeping it
        // honest here means the two agree about how much footage is left.
        steps[steps.count - 1].clipEnd = burstOutputDuration

        return Plan(requestedRamp: requestedRamp, appliedRamp: fitted.ramp, steps: steps)
    }

    // MARK: - Applying

    /// Retimes the burst clip occupying `[start, start + duration)` on every
    /// track it spans. Returns how many ranges were actually scaled.
    ///
    /// **Order matters, and it runs backwards.** `scaleTimeRange` rewrites the
    /// track's timeline from the scaled range onward, so anything at a later
    /// time moves. Walking the steps last-to-first means every range this
    /// method is about to touch is still exactly where `insertTimeRange` put
    /// it — no cursor to keep in sync, and no chance of the composition
    /// rounding a step to a different length than asked for and dragging the
    /// rest of the clip out of position. (The same reasoning applies across
    /// clips: a composition with several bursts must have its plans applied
    /// back to front too.)
    ///
    /// Every range is checked against the clip and the track before it is used;
    /// a range that would reach past either is skipped and logged rather than
    /// handed to AVFoundation, which accepts it silently and then fails the
    /// export with nothing more useful than "the operation could not be
    /// completed".
    @discardableResult
    static func apply(
        _ plan: Plan,
        to tracks: [AVMutableCompositionTrack],
        startingAt start: CMTime,
        duration: CMTime
    ) -> Int {
        guard !tracks.isEmpty, !plan.steps.isEmpty else { return 0 }
        guard start >= .zero, duration > .zero else {
            LLog("burst-ramp: refusing clip at \(start.seconds)s of \(duration.seconds)s")
            return 0
        }
        // The clip has to be inside every track it is about to be scaled on.
        let clipEnd = start + duration
        for track in tracks where clipEnd > track.timeRange.end {
            LLog("burst-ramp: clip ends \(clipEnd.seconds)s past track end "
                 + "\(track.timeRange.end.seconds)s — skipped")
            return 0
        }

        // Fine enough that even a minimum-length step is hundreds of ticks.
        let timescale: CMTimeScale = 60_000

        // Absolute boundaries, both domains. The clip's own end is the real
        // CMTime, never a Double round-trip, so the last range lands exactly on
        // the end of the footage.
        var clipBounds: [CMTime] = [.zero]
        var outputBounds: [CMTime] = [.zero]
        for (index, step) in plan.steps.enumerated() {
            let isLast = index == plan.steps.count - 1
            var bound = isLast ? duration : CMTime(seconds: step.clipEnd, preferredTimescale: timescale)
            // Monotonic and inside the clip, whatever rounding did.
            bound = min(max(bound, clipBounds[index]), duration)
            clipBounds.append(bound)
            outputBounds.append(CMTime(seconds: step.outputEnd, preferredTimescale: timescale))
        }

        var scaled = 0
        for index in stride(from: plan.steps.count - 1, through: 0, by: -1) {
            let sourceDuration = clipBounds[index + 1] - clipBounds[index]
            let targetDuration = outputBounds[index + 1] - outputBounds[index]
            // A step that rounded away, or the untouched middle, is a no-op —
            // and a zero target duration would delete footage rather than
            // speed it up.
            guard plan.steps[index].isScaled,
                  sourceDuration > .zero,
                  targetDuration > .zero,
                  sourceDuration != targetDuration else { continue }

            let range = CMTimeRange(start: start + clipBounds[index], duration: sourceDuration)
            guard range.end <= clipEnd else {
                LLog("burst-ramp: step \(index) ends \(range.end.seconds)s past the clip — skipped")
                continue
            }
            for track in tracks {
                track.scaleTimeRange(range, toDuration: targetDuration)
            }
            scaled += 1
        }
        return scaled
    }
}

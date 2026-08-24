import Foundation

/// Compiles a warp timeline over a STILLS sequence into the stacker's window
/// schedule — the interval counterpart of `WarpCompiler`, in the interval
/// vocabulary: a stretch's "speed" is its blend depth, frames per output
/// frame, exactly what the old whole-shoot BLEND slider meant. "Slower" is a
/// shallower stack (depth 1 plays every photo), "faster" a deeper one.
///
/// Where the video compiler integrates seconds×fps, this one walks the frames
/// themselves: every source frame lands in exactly one window (the warp
/// invariant — never a trim), each window as deep as the stretch its first
/// frame falls in. A trivial single-stretch timeline therefore compiles to
/// exactly `WindowSchedule.make(totalInputFrames:ramp:.constant(depth))` —
/// ceil(N ÷ depth) windows with a short tail — so an untouched timeline
/// renders what the slider always rendered.
///
/// Seams are steps by construction: depth is an integer per window, so an
/// "ease" could only staircase across a few windows — offered nowhere in the
/// interval vocabulary until someone wants it.
public enum IntervalWarp {

    public struct Compiled: Equatable, Sendable {
        /// Frames per output frame, in capture order. Sums to the input count.
        public var windows: [Int]
        /// Each window's first frame's position on the shoot's axis.
        public var windowSeconds: [Double]
        /// Output frames landing in each stretch — the bar's real shares.
        public var stretchWindows: [Int]
        /// Authored pacing on the capture clock: one presentation second per
        /// output frame. Within each stretch the windows keep their real
        /// capture spacing proportionally (the phase-1 honesty), while the
        /// stretch's total output span stays what its depth authored — so a
        /// ramped shoot's widening gaps still read, and a depth change still
        /// paces the clip. nil when the shoot has no clock (constant layout).
        public var presentationSeconds: [Double]?
        public var outputFrames: Int { windows.count }
    }

    /// `frameSeconds` are the frames' positions on the shoot's axis, monotonic
    /// non-decreasing (elapsed capture seconds, or uniform stand-ins);
    /// `bounds`/`depths` are the timeline's stretch boundaries and per-stretch
    /// depths on that same axis. Returns nil when the inputs can't describe a
    /// sequence (fewer than two frames, or a malformed timeline).
    public static func compile(
        frameSeconds: [Double],
        hasClock: Bool,
        bounds: [Double],
        depths: [Double],
        outputFPS: Double
    ) -> Compiled? {
        let frameCount = frameSeconds.count
        guard frameCount >= 2, outputFPS > 0,
              depths.count >= 1, bounds.count == depths.count + 1 else { return nil }

        func stretchIndex(at second: Double) -> Int {
            for index in 0..<depths.count where second < bounds[index + 1] {
                return index
            }
            return depths.count - 1
        }

        var windows: [Int] = []
        var windowSeconds: [Double] = []
        var windowStretch: [Int] = []
        var stretchWindows = [Int](repeating: 0, count: depths.count)
        var index = 0
        while index < frameCount {
            let second = frameSeconds[index]
            let stretch = stretchIndex(at: second)
            let depth = max(1, Int(depths[stretch].rounded()))
            let take = min(depth, frameCount - index)
            windows.append(take)
            windowSeconds.append(second)
            windowStretch.append(stretch)
            stretchWindows[stretch] += 1
            index += take
        }

        return Compiled(
            windows: windows,
            windowSeconds: windowSeconds,
            stretchWindows: stretchWindows,
            presentationSeconds: hasClock
                ? presentation(
                    windowSeconds: windowSeconds,
                    windowStretch: windowStretch,
                    outputFPS: outputFPS)
                : nil)
    }

    /// Per-stretch proportional layout. Frames are walked in axis order, so
    /// each stretch's windows form one consecutive run; each run spreads its
    /// windows across its own nominal span — (count − 1) ÷ fps, anchored at
    /// the run's cumulative start — proportionally to their capture moments.
    /// For a single run this is exactly `FrameTimeMapping.presentationSeconds`,
    /// which is what keeps an unedited timeline's render identical to the
    /// pre-timeline one.
    private static func presentation(
        windowSeconds: [Double],
        windowStretch: [Int],
        outputFPS: Double
    ) -> [Double]? {
        guard windowSeconds.count >= 2 else { return nil }
        guard let first = windowSeconds.first, let last = windowSeconds.last,
              last > first else { return nil }
        var result = [Double]()
        result.reserveCapacity(windowSeconds.count)
        var runStart = 0
        var outCursor = 0
        while runStart < windowSeconds.count {
            var runEnd = runStart + 1
            while runEnd < windowSeconds.count, windowStretch[runEnd] == windowStretch[runStart] {
                runEnd += 1
            }
            let count = runEnd - runStart
            let head = windowSeconds[runStart]
            let span = windowSeconds[runEnd - 1] - head
            for position in runStart..<runEnd {
                if count == 1 || span <= 0 {
                    // One window, or a burst stamped inside one instant —
                    // constant ticks are the only honest layout.
                    result.append(Double(outCursor + position - runStart) / outputFPS)
                } else {
                    let fraction = (windowSeconds[position] - head) / span
                    result.append((Double(outCursor) + fraction * Double(count - 1)) / outputFPS)
                }
            }
            outCursor += count
            runStart = runEnd
        }
        return result
    }
}

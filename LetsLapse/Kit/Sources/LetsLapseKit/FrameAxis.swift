import Foundation

/// The time axis of a stills sequence: where each captured frame sits in the
/// shoot, and which frame is on screen at a given moment.
///
/// One definition for every scrubber over an interval shoot's frames — the
/// photo editor's grade strip today, the warp timeline's stills lane next —
/// so "which frame is at this position" cannot drift between screens. Three
/// honesties, in falling order of knowledge:
///
/// - **A clock**: the shoot wrote `frames.timestamps` and the sidecar covers
///   exactly these frames — the axis is elapsed capture seconds, and uneven
///   spacing (an exposure ramp, a re-paced EVERY) is preserved.
/// - **A duration**: no per-frame clock, but the shoot's span is known — the
///   frames are laid out evenly across it.
/// - **Frames**: nothing but a count. `span` is 0 and positions map straight
///   to indices; frame numbers are the only axis that isn't invented.
public struct FrameAxis: Equatable, Sendable {

    public let frameCount: Int
    /// Elapsed capture seconds per frame, monotonic from 0 — present only on
    /// a clock axis.
    public let seconds: [Double]?
    /// The whole shoot's length in seconds: the clock's last stamp, or the
    /// provided uniform duration, or 0 when neither exists.
    public let span: Double

    /// Builds the best axis the inputs can honestly support. `elapsedSeconds`
    /// is trusted only when it describes exactly `frameCount` frames with a
    /// positive span — a sidecar for some other set of frames (a filtered
    /// blend, a foreign folder) falls through to the uniform axis rather than
    /// being guessed at.
    public init(frameCount: Int, elapsedSeconds: [Double]? = nil, uniformDuration: Double? = nil) {
        self.frameCount = max(0, frameCount)
        if let elapsedSeconds, elapsedSeconds.count == self.frameCount,
           let last = elapsedSeconds.last, last > 0 {
            self.seconds = elapsedSeconds
            self.span = last
        } else {
            self.seconds = nil
            self.span = max(0, uniformDuration ?? 0)
        }
    }

    /// True when the axis is the shoot's own capture clock.
    public var hasClock: Bool { seconds != nil }

    /// The frame under a 0…1 playhead. Index-linear on every axis — a
    /// scrubber's travel visits each frame equally, which is what a grading
    /// strip wants — with the clock consulted through `second(atIndex:)` for
    /// what moment that frame is.
    public func index(atPosition position: Double) -> Int {
        guard frameCount > 1 else { return 0 }
        let clamped = min(max(position, 0), 1)
        let index = Int((Double(frameCount - 1) * clamped).rounded())
        return min(max(index, 0), frameCount - 1)
    }

    /// The moment a frame was captured, in elapsed seconds. Uniform axes
    /// interpolate across the span; a span-less axis answers 0 for everything,
    /// which is the honest reading of "no time recorded".
    public func second(atIndex index: Int) -> Double {
        guard frameCount > 1 else { return 0 }
        let clamped = min(max(index, 0), frameCount - 1)
        if let seconds { return seconds[clamped] }
        return span * Double(clamped) / Double(frameCount - 1)
    }

    /// The frame on screen at a moment: the last frame captured at or before
    /// `second`, because a still holds until the next one lands. Clamped at
    /// both ends, so a caller can sweep any range without guarding.
    public func index(atSecond second: Double) -> Int {
        guard frameCount > 1, span > 0 else { return 0 }
        if let seconds {
            // Monotonic by the sidecar's construction — binary search for the
            // last stamp ≤ the query.
            var low = 0
            var high = frameCount - 1
            guard second >= seconds[0] else { return 0 }
            while low < high {
                let mid = (low + high + 1) / 2
                if seconds[mid] <= second { low = mid } else { high = mid - 1 }
            }
            return low
        }
        let stride = span / Double(frameCount - 1)
        let index = Int((min(max(second, 0), span) / stride).rounded(.down))
        return min(max(index, 0), frameCount - 1)
    }
}

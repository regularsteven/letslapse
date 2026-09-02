import Foundation

/// How fast the blend engine's video tap streams while a shoot runs — the
/// thermal lever (Settings ▸ Advanced ▸ Performance ▸ Capture stream rate).
///
/// The JPEG blend path used to stream the full-resolution tap at the
/// format's pinned rate for the whole run regardless of depth: a depth-1 run
/// at 2 s threw away 59 of every 60 frames while the ISP worked flat out,
/// and the iPhone 12 Pro reached thermal critical — where its lens
/// stabiliser parks and the framing jumps — in 12–16 minutes that way.
/// Streaming at what the window actually needs held the same phone below
/// critical for an hour of combined shooting on 2026-09-02. Apple's own
/// guidance for camera system pressure is this exact lever
/// (`AVCaptureDevice.systemPressureState`: "lowering the device's
/// activeVideoMinFrameDuration").
///
/// The preview shares the stream, so it slows with it; nothing about the
/// pixels changes — same lens, format and resolution, only how many raw
/// frames feed a window.
enum StreamRatePolicy: String, CaseIterable, Identifiable {
    /// Full rate while the camera is cool; the depth's need (with headroom)
    /// from the moment the camera reports serious pressure; back up when it
    /// cools. A device that has needed it on `StreamRateLearning.runsToLearn`
    /// runs starts reduced from frame 0 thereafter.
    case auto
    /// Reduced from frame 0 — what a device that has learned it needs does
    /// under Auto, chosen by hand.
    case reduced
    /// Never throttled. The critical stop still applies: this changes heat,
    /// not the rule.
    case full

    var id: String { rawValue }

    static let defaultsKey = "capture.streamRate"

    static var current: StreamRatePolicy {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(StreamRatePolicy.init(rawValue:)) ?? .auto
    }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .reduced: return "Reduced"
        case .full: return "Full"
        }
    }
}

/// Auto's self-learning: a device that keeps needing the throttle starts
/// reduced. Per device by construction (UserDefaults). Setting the policy to
/// Auto again resets it.
enum StreamRateLearning {
    static let engagedRunsKey = "capture.streamRate.autoEngagedRuns"
    static let learnedReducedKey = "capture.streamRate.learnedReduced"
    /// Auto runs on which the throttle had to engage before the device is
    /// marked as needing it from the start.
    static let runsToLearn = 3

    static var engagedRuns: Int {
        get { UserDefaults.standard.integer(forKey: engagedRunsKey) }
        set { UserDefaults.standard.set(newValue, forKey: engagedRunsKey) }
    }

    static var learnedReduced: Bool {
        get { UserDefaults.standard.bool(forKey: learnedReducedKey) }
        set { UserDefaults.standard.set(newValue, forKey: learnedReducedKey) }
    }

    /// Records the end of an Auto run. `engaged` = the serious-pressure floor
    /// was applied at least once during it.
    static func noteAutoRun(engaged: Bool) {
        guard engaged, !learnedReduced else { return }
        engagedRuns += 1
        if engagedRuns >= runsToLearn {
            learnedReduced = true
            LLog("stream rate: this device needed the throttle on \(engagedRuns) runs — Auto now starts reduced")
        }
    }

    static func reset() {
        engagedRuns = 0
        learnedReduced = false
    }
}

/// The arithmetic, in one place so the dial, the run and the settings row
/// agree about it.
enum StreamRatePlan {
    /// Start rate for a throttled run: twice the strict need, so a frame the
    /// camera drops is one the window can still fill.
    static let startHeadroom = 2.0
    /// The serious-pressure floor. Exactly the need loses frames — the
    /// selection grid has no slack, and the 2026-09-02 10-blend run delivered
    /// 8 of 10 in every window at 1× — so the floor keeps half a frame's
    /// worth of headroom per target.
    static let floorHeadroom = 1.5
    /// Where the open-ended depths (Psycho, Auto) land at serious pressure.
    /// The 2026-08-25 bench measured iOS's own serious-state camera budget at
    /// ~6–7 fps on both iPhones; half of that is margin, not a guess at the
    /// limit.
    static let openDepthPressuredFPS = 3.0
    /// A fixed depth is offered only when the stream can deliver it with
    /// this much headroom over the strict need — at 1× the grid drops frames.
    static let attainableHeadroom = 1.25

    /// Frames per second the depth strictly needs; nil for open-ended depths.
    static func neededFPS(depth: BlendDepth, intervalSeconds: Double, throttledTarget: Int?) -> Double? {
        guard intervalSeconds > 0 else { return nil }
        switch depth {
        case .fixed(let frames): return Double(max(1, frames)) / intervalSeconds
        case .throttled: return throttledTarget.map { Double(max(1, $0)) / intervalSeconds }
        case .unthrottled, .auto: return nil
        }
    }

    /// The rate a run opens at; nil = leave the configured rate alone.
    static func startFPS(policy: StreamRatePolicy, neededFPS: Double?, learnedReduced: Bool) -> Double? {
        switch policy {
        case .full: return nil
        case .reduced: return neededFPS.map { $0 * startHeadroom }
        case .auto: return learnedReduced ? neededFPS.map { $0 * startHeadroom } : nil
        }
    }

    /// The rate a run drops to when the camera reports serious pressure;
    /// nil = never.
    static func floorFPS(policy: StreamRatePolicy, neededFPS: Double?) -> Double? {
        switch policy {
        case .full: return nil
        case .reduced, .auto: return neededFPS.map { $0 * floorHeadroom } ?? openDepthPressuredFPS
        }
    }

    /// Whether a fixed count is offered at this interval on a stream pinned
    /// at `streamFPS` (nil = no stream bound, e.g. the RAW photo path).
    static func isAttainable(frames: Int, intervalSeconds: Double, streamFPS: Double?) -> Bool {
        guard let streamFPS, streamFPS > 0, intervalSeconds > 0, frames > 1 else { return true }
        return Double(frames) / intervalSeconds * attainableHeadroom <= streamFPS + 0.001
    }

    /// The rate a count needs to be offered, for the greyed row's caption.
    static func requiredFPS(frames: Int, intervalSeconds: Double) -> Double {
        guard intervalSeconds > 0 else { return 0 }
        return Double(frames) / intervalSeconds * attainableHeadroom
    }
}

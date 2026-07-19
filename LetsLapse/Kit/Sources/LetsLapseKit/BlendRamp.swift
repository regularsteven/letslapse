import Foundation

/// Easing applied across the clip when ramping the blend window.
public enum BlendCurve: String, CaseIterable, Sendable {
    case linear
    case easeIn = "ease-in"
    case easeOut = "ease-out"
    case easeInOut = "ease-in-out"

    /// Maps progress t in [0, 1] to an eased value in [0, 1].
    public func value(at t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear:
            return t
        case .easeIn:
            return t * t
        case .easeOut:
            return t * (2 - t)
        case .easeInOut:
            return t * t * (3 - 2 * t)
        }
    }
}

/// Describes how many input frames feed each output frame across the clip.
/// `startWindow == endWindow` is a constant blend; otherwise the window ramps
/// from `startWindow` to `endWindow` following `curve`.
public struct BlendRamp: Sendable, Equatable {
    public var startWindow: Int
    public var endWindow: Int
    public var curve: BlendCurve

    public init(startWindow: Int, endWindow: Int, curve: BlendCurve = .linear) {
        self.startWindow = max(1, startWindow)
        self.endWindow = max(1, endWindow)
        self.curve = curve
    }

    public static func constant(_ window: Int) -> BlendRamp {
        BlendRamp(startWindow: window, endWindow: window)
    }

    /// Window size at clip progress t in [0, 1].
    public func window(atProgress t: Double) -> Int {
        let eased = curve.value(at: t)
        let size = Double(startWindow) + (Double(endWindow) - Double(startWindow)) * eased
        return max(1, Int(size.rounded()))
    }
}

/// Precomputes the per-output-frame window sizes for a clip.
/// Windows are consecutive and non-overlapping. Progress is measured over the
/// input timeline, so the ramp spans the whole source clip no matter how many
/// output frames it ends up producing.
public enum WindowSchedule {
    public static func make(totalInputFrames: Int, ramp: BlendRamp) -> [Int] {
        guard totalInputFrames > 0 else { return [] }
        var windows: [Int] = []
        var consumed = 0
        while consumed < totalInputFrames {
            let t = Double(consumed) / Double(totalInputFrames)
            let window = min(ramp.window(atProgress: t), totalInputFrames - consumed)
            windows.append(window)
            consumed += window
        }
        return windows
    }
}

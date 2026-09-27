import Foundation
import os

/// Signposts for Instruments — the phases `docs/performance-baseline-plan.md`
/// measures. Every interval and event lands in the *Points of Interest* lane
/// of any trace, so a Time Profiler run shows the launch walk, the export,
/// the PicPlace check, Settings' free-up estimate and each photo's press →
/// pin → fire → recorded beside the samples, with no clock-matching against
/// the console log. Free when nothing records: a signpost is a no-op unless
/// a tool is listening.
///
/// Read them back without Instruments' UI:
///   xcrun xctrace export --input <trace> --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]'
enum LLPerf {
    static let signposter = OSSignposter(subsystem: "com.regularsteven.letslapse", category: .pointsOfInterest)

    /// Begin a named interval; end it with `end(_:_:)`. Any thread.
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// An interval whose two ends are in different places (the launch walk
    /// begins in `loadLibrary` and ends in `finishWalk`): keyed by name, one
    /// open at a time per name.
    static func beginKeyed(_ name: StaticString) {
        let state = begin(name)
        keyedLock.withLock { keyed["\(name)"] = state }
    }

    static func endKeyed(_ name: StaticString) {
        let state: OSSignpostIntervalState? = keyedLock.withLock { keyed.removeValue(forKey: "\(name)") }
        if let state { end(name, state) }
    }

    /// A point in time, with a short note that Instruments shows on the flag.
    static func event(_ name: StaticString, _ note: String = "") {
        signposter.emitEvent(name, "\(note, privacy: .public)")
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static var keyed: [String: OSSignpostIntervalState] = [:]
    private static let keyedLock = NSLock()
}

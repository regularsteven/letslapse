import Foundation

/// The WatchConnectivity dictionary keys shared by the iPhone receiver and the
/// Watch remote. Kept in one place so both targets speak the same protocol.
enum WatchMessageKey {
    static let command = "command"
    static let value = "value"
    static let status = "status"
    static let recordingState = "recordingState"
    static let recordingStartedAt = "recordingStartedAt"
    static let sequenceMode = "sequenceMode"
    static let markerCount = "markerCount"
    static let rampIntervalCount = "rampIntervalCount"
    static let segmentCount = "segmentCount"
    static let isRampActive = "isRampActive"
    static let isRampHighRate = "isRampHighRate"
    static let message = "message"
    static let cameraActive = "cameraActive"
    static let formatLine = "formatLine"
    static let captureFPS = "captureFPS"
    /// The ramp sequence's locked base rate. `captureFPS` mirrors the ACTIVE
    /// segment (it reads the burst rate mid-burst), so the Watch's base chip
    /// labels itself from this instead.
    static let baseFPS = "baseFPS"
    /// The rate a burst will run at (`selectedRampFrameRate`), as opposed to
    /// `captureFPS` which reports whatever segment is running right now. A
    /// remote showing only the base rate can't tell you what ⚡ is about to do:
    /// the burst chips are durations (1s/4s/8s), never rates.
    static let rampFPS = "rampFPS"
    static let plannedSpeed = "plannedSpeed"
    static let outputFPS = "outputFPS"
    static let isExposureLocked = "isExposureLocked"
    static let lockedISO = "lockedISO"
    static let lockedShutter = "lockedShutter"
    static let lockedLensPosition = "lockedLensPosition"
    static let isoMin = "isoMin"
    static let isoMax = "isoMax"
    static let captureMode = "captureMode"
    static let intervalSeconds = "intervalSeconds"
    static let framesPerBlend = "framesPerBlend"
    static let blendDepth = "blendDepth"
    /// Photo mode's Bulb (hold-open) toggle, mirrored so the Watch can label
    /// its start/stop control. The generic start/stop commands drive it — the
    /// phone routes a stop to `stopInterval` while the Bulb burst runs.
    static let isBulbMode = "isBulbMode"
    /// "active" while the phone app is on screen (foreground or briefly
    /// covered by Control Center), "background" once it truly leaves. Lets the
    /// Watch tell "app open on another tab" from "phone locked in a pocket".
    static let phoneAppState = "phoneAppState"
    static let captureCount = "captureCount"
    static let stopAtUnit = "stopAtUnit"
    static let stopAtDeadline = "stopAtDeadline"
    static let stopAtTargetCount = "stopAtTargetCount"
}

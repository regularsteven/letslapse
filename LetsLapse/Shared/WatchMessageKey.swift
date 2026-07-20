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
    static let plannedSpeed = "plannedSpeed"
    static let outputFPS = "outputFPS"
    static let isExposureLocked = "isExposureLocked"
    static let lockedISO = "lockedISO"
    static let lockedShutter = "lockedShutter"
    static let lockedLensPosition = "lockedLensPosition"
    static let isoMin = "isoMin"
    static let isoMax = "isoMax"
}

import Foundation

/// The command vocabulary the remote speaks to the capture screen, and the
/// recording state it hears back. Paired with `WatchMessageKey` (the dictionary
/// keys) these are the whole wire protocol.
///
/// Both live here rather than beside their users because the protocol has two
/// ends and neither owns it: the receiver used to declare them inside
/// `#if os(iOS)`, so the remote couldn't see them and sent bare strings — a
/// typo on either side degraded to "Unknown command" at runtime instead of
/// failing to build. Nothing here may reference a platform framework; the
/// transport is deliberately not part of the vocabulary.
enum WatchCaptureCommand: String {
    case startRecording
    case stopRecording
    case triggerMoment
    case timedBurst
    case lockExposure
    case unlockExposure
    case setISO
    case setLensPosition
    case setCaptureMode
    case setIntervalSeconds
    case setFramesPerBlend
    case scheduleStop
    case cancelScheduledStop
    /// A state poll, not an action. The receiver answers it before its
    /// app-active and command-handler guards, so it stays truthful about a
    /// backgrounded phone rather than being refused by it.
    case state
}

enum WatchRecordingState: String {
    case idle
    case recording
}

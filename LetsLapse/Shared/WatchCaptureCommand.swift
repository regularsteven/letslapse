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
    /// The rate a burst switches to (`selectedRampFrameRate`). Only rates in
    /// `availableBurstFPS` are accepted — the capability matrix has already
    /// dropped the ones that would change optic or codec mid-sequence, so a
    /// remote offering anything else would be offering a burst that can't run.
    case setBurstFPS
    case scheduleStop
    case cancelScheduledStop
    /// Bring the camera back without touching the phone. Presents the capture
    /// screen over whatever is showing — including a setup flow, which stays
    /// underneath and intact. Deliberately refused while a blend is running:
    /// the camera and the render would fight for the same GPU, and the remote
    /// offers "cancel export" for that case instead.
    case armCamera
    /// Stop a running blend so the camera can have the phone back.
    case cancelExport
    /// A look through the lens, plus how level the phone is. A request, not an
    /// action — the reply carries the frame, so one round trip answers both
    /// "what does it see" and "what is it doing".
    case previewFrame
    /// A state poll, not an action. The receiver answers it before its
    /// app-active and command-handler guards, so it stays truthful about a
    /// backgrounded phone rather than being refused by it.
    case state
}

extension WatchCaptureCommand {
    /// Whether a person asked for this, or the remote did.
    ///
    /// Only a person's command earns a failure banner. `state` polls fail
    /// routinely on a wrist that drifts out of range and self-heal on the next
    /// poll; surfacing those would train people to dismiss banners, and the
    /// one banner that matters is the one saying a control they just touched
    /// did nothing.
    var isUserInitiated: Bool {
        switch self {
        case .state, .previewFrame:
            // Both are polls. A dropped frame self-heals a second later, and
            // a banner per missed frame would bury the failures that matter.
            return false
        case .startRecording, .stopRecording, .triggerMoment, .timedBurst,
             .lockExposure, .unlockExposure, .setISO, .setLensPosition,
             .setCaptureMode, .setIntervalSeconds, .setFramesPerBlend,
             .setBurstFPS, .scheduleStop, .cancelScheduledStop,
             .armCamera, .cancelExport:
            return true
        }
    }

    /// What the control still reads, in words, when this command fails. The
    /// banner names the thing that did NOT change — "AE/AF Lock is still OFF"
    /// beats "command failed", because it tells you what you are looking at.
    func unchangedDescription(isExposureLocked: Bool) -> String? {
        switch self {
        case .lockExposure, .unlockExposure:
            return "AE/AF Lock is still \(isExposureLocked ? "ON" : "OFF")."
        case .startRecording:
            return "Nothing is recording."
        case .stopRecording:
            return "The phone is still recording."
        case .triggerMoment, .timedBurst:
            return "No burst was started."
        case .setBurstFPS:
            return "The burst rate is unchanged."
        case .setCaptureMode:
            return "The capture mode is unchanged."
        case .setIntervalSeconds, .setFramesPerBlend:
            return "The setting is unchanged."
        case .scheduleStop, .cancelScheduledStop:
            return "The scheduled stop is unchanged."
        case .armCamera:
            return "The camera is still closed."
        case .cancelExport:
            return "The export is still running."
        case .setISO, .setLensPosition, .state, .previewFrame:
            return nil
        }
    }
}

enum WatchRecordingState: String {
    case idle
    case recording
}

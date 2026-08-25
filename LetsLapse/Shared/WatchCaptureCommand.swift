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
    /// Field test: which Auto decision logic runs (`BlendStrategyID` raw
    /// value — zone / latitude / lumen). Idle-only like the depth itself;
    /// exists so a scripted multi-device test can configure each camera's
    /// strategy without a hand on the screen.
    case setBlendStrategy
    /// Arm a start at an absolute time (`value` = epoch seconds, ≤24h out;
    /// 0 cancels). The device fires its own shutter on its own clock, so a
    /// rig of cameras armed minutes apart still starts the same wall-clock
    /// second — and an overnight bench can arm a 5am dawn shoot and let
    /// the Mac sleep. Idle-only; a manual start before the hour simply
    /// wins (the timer re-checks idle before firing).
    case scheduleStart
    /// Interval's MODE dial — Off · Holy Grail · Scanner
    /// (`IntervalCaptureMode`). Idle-only: both non-`off` modes reconfigure the
    /// session for RAW at start, and Scanner adds a preview tap, neither of
    /// which can happen under a live run.
    ///
    /// Without this the remote could *start* a Holy Grail or Scanner shoot —
    /// `startRecording` dispatches on whatever the capture screen is set to —
    /// but only if someone had already armed the dial by hand, which is
    /// exactly the walk to the tripod the remote exists to avoid.
    case setIntervalMode
    /// EVERY on Auto: the MODE paces the shoot instead of a fixed spacing.
    /// Refused when the mode can't pace (Off) — the phone owns that rule, and
    /// the refusal is reported rather than silently accepted.
    case setAutoInterval
    /// Scanner only: discard the pose just captured without ending the shoot.
    /// The one Scanner control that isn't start or stop, and the one most
    /// worth having at a distance — the operator is at the object, and the
    /// pose that needs re-shooting is still in front of them.
    case deleteLastFrame
    /// The rate a burst switches to (`selectedRampFrameRate`). Only rates in
    /// `availableBurstFPS` are accepted — the capability matrix has already
    /// dropped the ones that would change optic or codec mid-sequence, so a
    /// remote offering anything else would be offering a burst that can't run.
    case setBurstFPS
    /// The run's base frame rate — what everything outside a burst shoots at.
    /// Unlike the burst rate this DOES re-apply the capture format, so it is
    /// idle-only; the remote offers it on the armed screen and nowhere else.
    case setBaseFPS
    /// Ramp (bursts switch frame rate) versus marker (bursts annotate a moment
    /// at the rate already running). Baked into the sequence at start, so this
    /// is idle-only too.
    case setSequenceMode
    case scheduleStop
    case cancelScheduledStop
    /// Settings ▸ Advanced ▸ "Dim screen during shoot", from a distance.
    /// Display-only — the panel is a real slice of the thermal budget on the
    /// OLED phones — so unlike the capture setters this is accepted mid-run:
    /// flipping it live on a bench arm is exactly the A/B it exists for.
    case setDimDuringShoot
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
    /// Place a mark's IN, or close the open one with an OUT. Annotation only:
    /// no file, no rate change, no cost to the capture pipeline — which is why
    /// it is available in any mode and at any moment, where a burst is not.
    /// An optional `value` in seconds asks the phone to place the OUT on its
    /// own timer, so it lands even if the watch sleeps.
    case toggleMark
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
             .setBlendStrategy, .scheduleStart,
             .setIntervalMode, .setAutoInterval, .deleteLastFrame,
             .setBurstFPS, .setBaseFPS, .setSequenceMode, .toggleMark,
             .scheduleStop, .cancelScheduledStop, .setDimDuringShoot,
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
        case .setBaseFPS:
            return "The base frame rate is unchanged."
        case .setSequenceMode:
            return "The burst behaviour is unchanged."
        case .setCaptureMode:
            return "The capture mode is unchanged."
        case .setIntervalSeconds, .setFramesPerBlend:
            return "The setting is unchanged."
        case .setBlendStrategy:
            return "The blend strategy is unchanged."
        case .scheduleStart:
            return "No start is scheduled."
        case .setIntervalMode:
            return "The shoot mode is unchanged."
        case .setAutoInterval:
            return "The interval is unchanged."
        case .deleteLastFrame:
            return "No frame was deleted."
        case .scheduleStop, .cancelScheduledStop:
            return "The scheduled stop is unchanged."
        case .armCamera:
            return "The camera is still closed."
        case .cancelExport:
            return "The export is still running."
        case .toggleMark:
            return "No mark was placed."
        case .setDimDuringShoot:
            return "Screen dimming is unchanged."
        case .setISO, .setLensPosition, .state, .previewFrame:
            return nil
        }
    }
}

enum WatchRecordingState: String {
    case idle
    case recording
}

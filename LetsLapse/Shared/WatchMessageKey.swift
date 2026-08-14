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
    /// Every rate a burst could switch to at the current format, ascending.
    /// The remote's rate ladder draws one rung per entry and hatches the rest,
    /// so it can only ever offer what this camera can actually reach — an
    /// empty array means bursts have nowhere to go and the ladder says so.
    static let availableBurstFPS = "availableBurstFPS"
    /// Every base frame rate this lens and resolution can shoot, ascending.
    /// Its counterpart to `availableBurstFPS`: the remote's base-rate picker
    /// draws from it, so it can only offer what the camera can actually do.
    static let availableBaseFPS = "availableBaseFPS"
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

    // MARK: What the phone is doing instead of being a camera
    //
    // `cameraActive` says the capture screen isn't there; these say what IS.
    // Without them the remote can only offer "open the camera on iPhone",
    // which is advice, not a control — and useless if the phone is on a
    // tripod across a field.

    /// `home` · `setup` · `processing` · `done` — the phone's flow stage.
    static let phoneFlow = "phoneFlow"
    /// Human name of the flow in progress, e.g. "Guided Clip".
    static let flowTitle = "flowTitle"
    /// 1-based step and total, when the flow has countable steps.
    static let flowStep = "flowStep"
    static let flowStepCount = "flowStepCount"
    /// 0…1 through the running blend.
    static let exportProgress = "exportProgress"
    /// Seconds left, from the phone's own estimate. Absent when it has none
    /// yet — a wrong ETA is worse than no ETA.
    static let exportETASeconds = "exportETASeconds"
    /// "Creating 12.4s clip" / "Blended clip · camera unavailable".
    static let exportTitle = "exportTitle"
    static let exportSubtitle = "exportSubtitle"
    /// When the most recent capture was made, so an idle remote can say how
    /// long the phone has been sitting there.
    static let lastCaptureAt = "lastCaptureAt"

    // MARK: Framing preview

    /// A JPEG, base64-encoded into a String — NOT raw `Data`. The LAN
    /// transport JSON-encodes its bodies and `JSONSerialization` rejects
    /// `Data`, so a `Data` payload would work on the Watch and fail silently
    /// for the Mac and iPad remotes.
    static let previewImage = "previewImage"
    /// The frame's real pixel dimensions, so the remote can letterbox to the
    /// camera's actual aspect instead of guessing one.
    static let previewPixelWidth = "previewPixelWidth"
    static let previewPixelHeight = "previewPixelHeight"
    /// Signed degrees off level, measured on the PHONE. The watch's own
    /// attitude describes an arm, which says nothing about the horizon in the
    /// frame. Absent when motion data isn't available yet — the remote hides
    /// the horizon bar rather than drawing a confident zero.
    static let previewRollDegrees = "previewRollDegrees"
    static let stopAtUnit = "stopAtUnit"
    static let stopAtDeadline = "stopAtDeadline"
    static let stopAtTargetCount = "stopAtTargetCount"
}

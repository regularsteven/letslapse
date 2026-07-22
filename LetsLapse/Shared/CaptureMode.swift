import Foundation

/// The capture modes offered on the phone's capture screen. Lives in Shared/
/// so the Watch remote speaks the same vocabulary (mode selection and state
/// mirroring use the raw values on the wire).
enum CaptureMode: String, CaseIterable, Identifiable {
    case video = "Video"
    case interval = "Interval"
    /// Experimental spike: blends several camera frames into each timelapse
    /// image during capture.
    case liveBlend = "Live Blend"
    var id: String { rawValue }
}

/// Units for a scheduled stop ("stop at…") set from the Watch remote.
/// Frames mean captured photos/blends in Interval and Live Blend, and
/// fps-derived recorded frames in Video.
enum ScheduledStopUnit: String, CaseIterable {
    case minutes
    case frames
}

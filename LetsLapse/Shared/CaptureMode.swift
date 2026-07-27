import Foundation

/// The capture modes offered on the phone's capture screen. Lives in Shared/
/// so the Watch remote speaks the same vocabulary (mode selection and state
/// mirroring use the raw values on the wire).
enum CaptureMode: String, CaseIterable, Identifiable {
    /// The simple mode — one tap, one photo (or a short steadied burst that
    /// stacks into a single long exposure). Listed first: it's the least
    /// involved way to capture.
    case photo = "Photo"
    case interval = "Interval"
    case video = "Video"
    var id: String { rawValue }

    /// Decodes a mode token from the wire or from persisted defaults. The
    /// retired "Live Blend" mode maps onto Interval — blending became an
    /// Interval dial when the two modes merged — so stale Watch builds and
    /// old remembered-settings snapshots keep working.
    init?(token: String) {
        if token == "Live Blend" {
            self = .interval
            return
        }
        self.init(rawValue: token)
    }
}

/// Units for a scheduled stop ("stop at…") set from the Watch remote.
/// Frames mean captured photos/blends in Interval, and fps-derived recorded
/// frames in Video.
enum ScheduledStopUnit: String, CaseIterable {
    case minutes
    case frames
}

/// Output format for Interval shooting. DNG blends Bayer RAW captures into
/// a real raw file — white balance and tone stay adjustable in post — and
/// needs a RAW-capable camera source; JPEG is the path every source
/// supports.
enum IntervalOutputFormat: String, CaseIterable {
    /// Raw value stays "standard" — the pre-merge name this preference was
    /// persisted under.
    case jpeg = "standard"
    case dng
}

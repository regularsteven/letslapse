import Foundation

/// A shoot armed for a wall-clock time in the future.
///
/// This is the whole contract between "someone set an alarm on the capture
/// screen" and "the phone fires the shutter by itself". It carries the dials
/// the run needs rather than trusting whatever the screen happens to hold at
/// T=0: a scheduled sunrise shoot must fire with the spacing it was armed
/// with, even if the screen was left on a different number afterwards.
///
/// It is deliberately *not* a live capture state. The capture screen owns the
/// timers; this is only the persisted intent, so an app relaunch inside the
/// waiting window re-arms the same shoot rather than losing it.
struct ScheduledRecording: Codable, Equatable {
    /// When the shutter fires, on this device's own clock.
    var startDate: Date
    /// Capture interval for the shoot.
    var intervalSeconds: Double
    /// Run length; nil shoots until stopped by hand (or by the remote).
    var durationMinutes: Int?
    /// Frames averaged into each output image; nil keeps whatever the capture
    /// screen's BLEND dial is set to when the shoot fires.
    var blendDepth: Int?
    /// What the shoot is for — shown on the standby screen so a phone found
    /// on a tripod in the dark can say what it is waiting for.
    var label: String?

    /// Seconds until the shutter. Negative once the moment has passed.
    var secondsUntilStart: TimeInterval { startDate.timeIntervalSinceNow }
}

/// `ScheduledRecording`'s home in `UserDefaults`.
///
/// One key, one value, JSON-encoded — a schedule is a singleton by design.
/// Arming a second shoot replaces the first rather than queueing behind it,
/// which is the honest model for a device that has exactly one camera.
enum ScheduledRecordingStore {
    /// The key the brief names. Kept bare (no `letslapse.` prefix) because it
    /// is the documented contract for this feature.
    static let defaultsKey = "scheduledRecording"

    static func load(from defaults: UserDefaults = .standard) -> ScheduledRecording? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(ScheduledRecording.self, from: data)
    }

    static func save(_ recording: ScheduledRecording?, to defaults: UserDefaults = .standard) {
        guard let recording, let data = try? JSONEncoder().encode(recording) else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }
}

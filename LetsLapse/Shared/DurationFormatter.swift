import Foundation

enum DurationFormatter {
    static func recordingTime(from interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    /// How long ago something happened, in as few characters as read across a
    /// room: seconds up to a minute, then whole minutes, then hours. Used by
    /// the scheduled peek's "latest frame · 12 s ago" caption, where the
    /// number only has to be right enough to say the run is still moving.
    static func compactAge(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h"
    }
}

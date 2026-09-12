import SwiftUI

// Mirrors the "INTERVAL · 2 h 14 min · 58 frames" chip of boards 6a (over the
// iPhone's timeline card), 6b (beside the iPad's back button) and 6c (bottom-
// left of the Mac's media pane) — spec §4 and §5: the one line that says what
// the strip under it is measuring.

/// The kind-and-length chip: `INTERVAL · 2 h 14 min · 58 frames`.
///
/// It floats over black chrome on every platform, so it is drawn once, dark,
/// and never takes the rail's light palette: 20 pt tall, `black 50 %`, 11 pt
/// semibold white. The text is assembled from whatever the project can say —
/// a photo has no length and no count, an interval shoot without a clock has
/// a count but no length — so a part that would be a guess is left out
/// rather than filled in.
struct EditorMarqueeBadge: View {
    enum Kind {
        case photo, interval, video

        var label: String {
            switch self {
            case .photo: return "PHOTO"
            case .interval: return "INTERVAL"
            case .video: return "VIDEO"
            }
        }
    }

    var kind: Kind
    /// The shoot's length in seconds, or nil where none was recorded.
    var durationSeconds: Double?
    /// How many frames the strip walks; a photo passes nil rather than 1.
    var frameCount: Int?

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 20)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(accessibilityText)
    }

    private var text: String {
        var parts = [kind.label]
        if let durationSeconds, durationSeconds > 0 {
            parts.append(Self.durationLabel(seconds: durationSeconds))
        }
        if let frameCount, frameCount > 1 {
            parts.append("\(frameCount) frames")
        }
        return parts.joined(separator: " · ")
    }

    /// Spoken from the parts, not the display text: `.capitalized` over
    /// "6 min 4 s" made VoiceOver read the units as the word "Min" and the
    /// letter "S".
    private var accessibilityText: String {
        var parts = [kind.label.capitalized]
        if let durationSeconds, durationSeconds > 0 {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.hour, .minute, .second]
            if let spoken = formatter.string(from: max(0, durationSeconds.rounded())) {
                parts.append(spoken)
            }
        }
        if let frameCount, frameCount > 1 {
            parts.append("\(frameCount) frames")
        }
        return parts.joined(separator: ", ")
    }

    /// "2 h 14 min" / "14 min 3 s" / "45 s" — the largest two units that are
    /// not zero, rounded to whole seconds; an exact hour reads "2 h" rather
    /// than "2 h 0 min".
    static func durationLabel(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h"
        }
        if minutes > 0 {
            return secs > 0 ? "\(minutes) min \(secs) s" : "\(minutes) min"
        }
        return "\(secs) s"
    }
}

#if DEBUG
#Preview("Marquee badge") {
    VStack(alignment: .leading, spacing: 12) {
        EditorMarqueeBadge(kind: .interval, durationSeconds: 8040, frameCount: 58)
        EditorMarqueeBadge(kind: .interval, durationSeconds: 843, frameCount: 250)
        EditorMarqueeBadge(kind: .interval, durationSeconds: nil, frameCount: 12)
        EditorMarqueeBadge(kind: .photo, durationSeconds: nil, frameCount: nil)
    }
    .padding(20)
    .background(Color(red: 0.3, green: 0.35, blue: 0.4))
}
#endif

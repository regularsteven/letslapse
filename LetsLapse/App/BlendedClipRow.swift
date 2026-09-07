import SwiftUI

/// One row in a project's BLENDED CLIPS list: a rendered blend, a stacked
/// photo/interval image result, or a time-sliced export. Shared by
/// `ProjectDetailView`'s own list and the macOS Gallery preview panel — see
/// `docs/design/components/blended-clip-row.<state>.<width>.svg` for the
/// design contract both mirror (thumbnail 58×42, 12pt gap, trailing "Open").
struct BlendedClipRow: View {
    var blend: AppModel.BlendProject
    @ObservedObject var model: AppModel
    var onPlay: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    ProjectThumbnailView(
                        url: model.mediaURL(for: blend), kind: model.mediaKind(for: blend))
                        .frame(width: 58, height: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play blended clip \(model.versionNumber(for: blend))")

            Button("Open", action: onOpen)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // Sliced outputs are named by their recipe (decided 2026-08-28):
    // timeslice-vert-left-segs_24-lag_2, the poster without the lag.
    private var title: String {
        if let timeSlice = blend.timeSlice {
            var parts = [blend.kind == .image
                ? timeSlice.posterDisplayName : timeSlice.displayName]
            if let seconds = blend.outputSeconds {
                parts.append(SpeedMath.clipLength(seconds))
            }
            return parts.joined(separator: " · ")
        }
        var parts = ["Blended clip \(model.versionNumber(for: blend))", blend.speedLabel]
        if let seconds = blend.outputSeconds {
            parts.append(SpeedMath.clipLength(seconds))
        }
        return parts.joined(separator: " · ")
    }

    private var subtitle: String {
        var parts: [String] = []
        if blend.kind == .video, let fps = blend.outputFPS {
            parts.append("\(fps) fps")
        }
        if let codecLabel = blend.sourceCodecLabel {
            parts.append("from \(codecLabel)")
        }
        if blend.linearLight {
            parts.append("true-light")
        }
        parts.append(blend.createdAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

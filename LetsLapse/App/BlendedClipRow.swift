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
        // The blend's file may be on PicPlace, not here (free up space, or a
        // project pulled as a preview): the row keeps its still, says where
        // the clip is, and offers the download instead of a player that
        // would open nothing (2026-09-23).
        let missing = model.blendFileMissing(blend)
        let poster = missing ? model.blendPosterURL(for: blend) : nil
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    ProjectThumbnailView(
                        url: poster.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? (missing ? nil : model.mediaURL(for: blend)),
                        kind: missing ? .image : model.mediaKind(for: blend))
                        .frame(width: 58, height: 42)
                        .overlay(alignment: .bottomTrailing) {
                            if missing {
                                Image(systemName: "icloud")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(Color.black.opacity(0.5), in: Circle())
                                    .padding(3)
                            }
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .lineLimit(1)
                        Text(missing ? "On PicPlace · " + subtitle : subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Nothing to play here — but not drawn disabled: the still and the
            // "On PicPlace" line say where the clip is.
            .allowsHitTesting(!missing)
            .accessibilityLabel(missing ? "Blended clip \(model.versionNumber(for: blend)), on PicPlace" : "Play blended clip \(model.versionNumber(for: blend))")

            if missing {
                if let capture = model.capture(for: blend) {
                    BlendDownloadButton(picplace: model.picplace, capture: capture)
                }
            } else {
                Button("Open", action: onOpen)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .buttonStyle(.plain)
                    // Opening re-blends from the originals, which may be on
                    // PicPlace only (the blend itself still plays).
                    .disabled(model.capture(for: blend).map(model.sourcesMissing) ?? true)
            }
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

/// A blend row's Download (its file is on PicPlace, not here): the blends of
/// the project, fetched together. Its own view so it follows the PicPlace
/// session and the download's progress, which the row's model does not
/// publish.
private struct BlendDownloadButton: View {
    @ObservedObject var picplace: PicPlaceController
    let capture: AppModel.CaptureProject

    var body: some View {
        if picplace.canSync {
            let busy = picplace.progress[capture.id] != nil
            Button(busy ? "Downloading…" : "Download") { picplace.downloadOriginals(capture, kinds: [.blend]) }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
                .disabled(busy)
        }
    }
}

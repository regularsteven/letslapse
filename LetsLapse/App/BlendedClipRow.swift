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
                        // The clip's holdings pill — layers when its file is
                        // here | PicPlace (the Gallery tile's, for one clip).
                        .overlay(alignment: .bottomTrailing) {
                            BlendHoldingsPill(blend: blend)
                                .scaleEffect(0.8, anchor: .bottomTrailing)
                                .padding(2)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .lineLimit(1)
                        Group {
                            if missing, let capture = model.capture(for: blend) {
                                BlendWhereLine(picplace: model.picplace, capture: capture, blend: blend, subtitle: subtitle)
                            } else {
                                Text(subtitle)
                            }
                        }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Not drawn disabled, and not dead either: the still and the line
            // under the title say where the clip is, and a tap is the parent's
            // `onPlay`, which asks to fetch it first (2026-09-25).
            .accessibilityLabel(missing ? "Blended clip \(model.versionNumber(for: blend)), not on this device" : "Play blended clip \(model.versionNumber(for: blend))")

            if missing {
                if let capture = model.capture(for: blend) {
                    BlendDownloadButton(picplace: model.picplace, capture: capture, blend: blend)
                }
            } else {
                Button("Open", action: onOpen)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .buttonStyle(.plain)
                    // Opening re-reads the originals, which may be on PicPlace
                    // only (the blend itself still plays): greyed in place,
                    // and the parent's `onOpen` asks to fetch them.
                    .opacity(model.capture(for: blend).map { model.isAvailable(.newBlend, for: $0) } ?? false ? 1 : 0.4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // A clip that is not here: PicPlace's list for its project says
        // whether it can come down (once a minute per project).
        .task(id: missing) {
            if missing, let capture = model.capture(for: blend) { model.picplace.askForListing(capture.id) }
        }
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

/// Where a clip that is not here is: on PicPlace (it can come down), not
/// available (PicPlace holds no copy — it is only on the device that made
/// it), or nothing said until PicPlace's list is read. Its own view so it
/// follows the list as it arrives (2026-09-26).
private struct BlendWhereLine: View {
    @ObservedObject var picplace: PicPlaceController
    let capture: AppModel.CaptureProject
    let blend: AppModel.BlendProject
    let subtitle: String

    var body: some View {
        let availability = picplace.blendAvailability(blend, of: capture)
        Group {
            switch availability {
            case .onPicPlace: Text("On PicPlace · " + subtitle)
            case .notOnPicPlace: Text("Not available to download · " + subtitle)
            case .unknown: Text(subtitle)
            }
        }
        #if DEBUG
        // What the row says, as it changes — the device check (2026-09-26).
        .onChange(of: availability, initial: true) { _, now in
            LLog("blend row: \(blend.id.uuidString.prefix(8)) of \(capture.displayTitle) — \(now)")
        }
        #endif
    }
}

/// A blend row's Download (its file is on PicPlace, not here): this blend
/// alone — a collection or a play needs one clip, not every blend of the
/// project (2026-09-25; it fetched them all). Offered only once PicPlace's
/// list shows the file there (2026-09-26 — it was offered for a blend never
/// uploaded). Its own view so it follows the PicPlace session, the list and
/// the download's progress, which the row's model does not publish.
private struct BlendDownloadButton: View {
    @ObservedObject var picplace: PicPlaceController
    let capture: AppModel.CaptureProject
    let blend: AppModel.BlendProject

    var body: some View {
        let busy = picplace.progress[capture.id] != nil
        if picplace.canSync, busy || picplace.blendAvailability(blend, of: capture) == .onPicPlace {
            Button(busy ? "Downloading…" : "Download") {
                picplace.downloadOriginals(capture, kinds: [.blend], only: [blend.outputFileName])
            }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
                .disabled(busy)
        }
    }
}

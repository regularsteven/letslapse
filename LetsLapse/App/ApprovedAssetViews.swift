import SwiftUI
import LetsLapseKit

// MARK: - Approved: the mark, the button, the Approved view's tile
//
// One glyph says "approved" wherever it is said (docs/approved-assets.md):
// `checkmark.seal.fill` in the accent. Never green — green is the holdings
// pill's "here" (connected asset states §16) — and never a cloud.

/// The approved mark on a picture: the accent seal on a dark disc, so it
/// reads over any thumbnail.
struct ApprovedSeal: View {
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size * 0.62, weight: .semibold))
            .foregroundStyle(.white, LL.accent)
            .symbolRenderingMode(.palette)
            .frame(width: size, height: size)
            .background(.black.opacity(0.5), in: Circle())
            .accessibilityLabel("Approved")
    }
}

/// The seal as a control, at the end of a clip row: outlined and grey until
/// the output is approved, then filled in the accent. A press toggles.
struct ApproveToggle: View {
    var isApproved: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isApproved ? "checkmark.seal.fill" : "checkmark.seal")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isApproved ? LL.accent : Color.secondary.opacity(0.7))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isApproved ? "Approved" : "Approve")
        .accessibilityAddTraits(isApproved ? .isSelected : [])
        #if os(macOS)
        .help(isApproved ? "Approved for use — click to remove the approval" : "Approve for use")
        #endif
    }
}

/// One approved output as a tile of the Gallery's Approved view: the
/// output's own picture — a blended clip's frame, an edited clip's, the
/// photo as edited, the source clip — under the badge that says which, the
/// seal top-leading. A click selects its project (the pane beside the grid
/// is the project's); a double click opens it.
struct ApprovedAssetTile: View {
    @EnvironmentObject var model: AppModel
    var asset: ApprovedAsset
    var capture: AppModel.CaptureProject
    var isSelected: Bool
    var onTap: () -> Void
    var onOpen: () -> Void
    var onOutsideTap: () -> Void = {}

    @State private var size: CGSize = .zero

    private var blend: AppModel.BlendProject? {
        if case .blend(let id) = asset.target { return model.blend(id: id) }
        return nil
    }

    var body: some View {
        let blend = self.blend
        ZStack(alignment: .bottomLeading) {
            thumbnail(blend)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(LL.accent, lineWidth: 2.5)
                    }
                }
            MediaBadge(text: Self.badge(for: asset, capture: capture, blend: blend))
                .padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if let blend {
                    BlendHoldingsPill(blend: blend)
                } else {
                    HoldingsPill(captureID: capture.id)
                }
            }
            .padding(6)
        }
        .overlay(alignment: .topLeading) {
            // The corner a project tile wears it in.
            ApprovedSeal(size: 22)
                .padding(6)
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onTapGesture(count: 1) { location in
            if size != .zero, !CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(location) {
                onOutsideTap()
            } else {
                onTap()
            }
        }
        .onTapGesture(count: 2) { onOpen() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(capture.displayTitle), \(Self.badge(for: asset, capture: capture, blend: blend)), approved")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open") { onOpen() }
    }

    @ViewBuilder
    private func thumbnail(_ blend: AppModel.BlendProject?) -> some View {
        if let blend {
            // As a clip row draws it: the clip's own frame, or its still
            // when the file is on PicPlace and not here.
            let missing = model.blendFileMissing(blend)
            let poster = missing ? model.blendPosterURL(for: blend) : nil
            ProjectThumbnailView(
                url: poster.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                    ?? (missing ? nil : model.mediaURL(for: blend)),
                kind: missing ? .image : model.mediaKind(for: blend),
                cornerRadius: 8)
        } else {
            // A photo is approved as edited, so it shows its look; a source
            // clip is approved as it is, so it shows none.
            let grade = model.photoGrade(for: capture)
            ProjectThumbnailView(
                url: model.thumbnailURL(for: capture), kind: model.mediaKind(for: capture), cornerRadius: 8,
                grade: capture.isPhotoCapture && !grade.isIdentity ? grade : nil)
        }
    }

    /// What kind of output the tile is, in a word or two.
    static func badge(for asset: ApprovedAsset, capture: AppModel.CaptureProject, blend: AppModel.BlendProject?) -> String {
        guard let blend else { return capture.isPhotoCapture ? "Photo" : "Video" }
        if blend.isEditRender { return "Edited clip" }
        if blend.timeSlice != nil { return blend.kind == .image ? "Time-slice poster" : "Time slice" }
        if blend.kind == .image { return "Image" }
        return capture.kind == .video ? "Blended clip" : "Timelapse"
    }
}

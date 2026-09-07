import SwiftUI

/// The two independent questions asked over a project's BLENDED CLIPS list —
/// Blends vs Slices (`blend.timeSlice == nil` vs `!= nil`) and Image vs Video
/// (`blend.kind`) — as four plain tick chips rather than two exclusive
/// pickers: ticking every chip already means "no filter", so there is no
/// separate "all" state to keep in sync. See
/// docs/design/components/blend-list-filter.<state>.<width>.svg and its
/// README for the design this mirrors.
struct BlendListFilter: Equatable {
    var showBlends = true
    var showSlices = true
    var showImage = true
    var showVideo = true

    /// A result is shown when it matches ANY ticked value in each pair —
    /// unticking both Blends and Slices (or both Image and Video) is a real,
    /// allowed empty state, not a case to special-case away.
    func matches(_ blend: AppModel.BlendProject) -> Bool {
        let typeMatches = blend.timeSlice == nil ? showBlends : showSlices
        let kindMatches = blend.kind == .video ? showVideo : showImage
        return typeMatches && kindMatches
    }
}

/// The tick-chip row: Blends, Slices, Image, Video. Styled like
/// `PresetStripSection`'s own chips (`ProjectDetailView.swift`) — a Capsule,
/// accent fill + white text + a leading checkmark when ticked, the card
/// background + primary text and no checkmark when not — since unlike a
/// segmented control this needs to say "more than one of these can be true
/// at once". All four fit one row at the iOS project-detail card's width;
/// the macOS Gallery preview panel's narrower column wraps them to two
/// rows — Blends/Slices, then Image/Video — via `ViewThatFits` rather than
/// two hand-maintained layouts.
struct BlendListFilterBar: View {
    @Binding var filter: BlendListFilter

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                HStack(spacing: 8) { blendsChip; slicesChip }
                HStack(spacing: 8) { imageChip; videoChip }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { blendsChip; slicesChip }
                HStack(spacing: 8) { imageChip; videoChip }
            }
        }
    }

    private var blendsChip: some View { chip("Blends", isOn: $filter.showBlends) }
    private var slicesChip: some View { chip("Slices", isOn: $filter.showSlices) }
    private var imageChip: some View { chip("Image", isOn: $filter.showImage) }
    private var videoChip: some View { chip("Video", isOn: $filter.showVideo) }

    private func chip(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                if isOn.wrappedValue {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(isOn.wrappedValue ? LL.accent : LL.cardBackground))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }
}

/// The message the card is replaced by when a filter combination matches
/// nothing — a real, expected state (e.g. Image unticked on an all-video
/// project), not an error. Matches Gallery's own empty-grid language
/// (`GalleryGridContent`'s "No projects" state).
struct BlendListEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No results")
                .font(.system(size: 16, weight: .semibold))
            Text("Try ticking another chip back on.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .llCard()
    }
}

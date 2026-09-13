import SwiftUI

// Mirrors the preset tiles of boards 2a (iPhone: a horizontal strip of 76 pt
// tiles with labels under), 5a (iPad: a 4-column grid of square tiles) and 3b
// (Mac: a 3-column grid of 72 pt tiles with the name inside) — spec §9.

/// How a preset tile is shaped for its surface.
enum PresetTileStyle {
    /// 2a: 76 × 76, label under.
    case phone
    /// 5a: square, fills its grid cell, label under.
    case padGrid
    /// 3b: 72 pt tall, name inside bottom-left, no label under.
    case macGrid
}

/// One preset in the Presets panel: a live thumbnail of the frame under the
/// playhead rendered through that preset with the current adjustments on
/// top, ringed in the accent when it is the one applied.
///
/// The tile draws whatever `image` it is handed and a placeholder while that
/// is nil; rendering, caching and refresh are the panel's business (spec §9:
/// off-main, keyed by preset + adjustments token + frame, refreshed on open
/// and on gesture end, never per tick). Keeping the tile stateless is what
/// lets the same view serve a scrolling strip, a grid and a card.
struct PresetTile: View {
    var name: String
    var image: CGImage?
    var isSelected: Bool
    /// `LL.amber` on the dark editors, `LL.accent` on the Mac.
    var accent: Color
    var style: PresetTileStyle
    /// True on the editors' dark sheets, which the phone and pad styles were
    /// drawn for; false where the same strip sits on a light card — the
    /// Gallery panel's Presets group (2026-09-13) — so the placeholder and the
    /// captions take the light palette instead. The Mac grid is light either
    /// way: its name is drawn over the picture.
    var isOnDark = true
    var action: () -> Void

    private var cornerRadius: CGFloat { style == .macGrid ? 10 : 12 }
    private var placeholder: Color {
        style == .macGrid || !isOnDark ? LL.controlFill : Color(white: 0x11 / 255.0)
    }

    var body: some View {
        Button(action: action) {
            switch style {
            case .phone:
                VStack(spacing: 5) {
                    picture.frame(width: 76, height: 76)
                    caption
                }
            case .padGrid:
                VStack(spacing: 5) {
                    picture.aspectRatio(1, contentMode: .fit)
                    caption
                }
            case .macGrid:
                picture
                    .frame(height: 72)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottomLeading) {
                        Text(name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                            .lineLimit(1)
                            .padding(.leading, 7)
                            .padding(.bottom, 5)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The thumbnail, filling its box and clipped to the tile's corners, with
    /// the selection ring drawn inside the edge (the board's border-box).
    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return placeholder
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(isSelected ? accent : Color.clear, lineWidth: 2.5))
            .contentShape(shape)
    }

    private var caption: some View {
        Text(name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isSelected ? accent : (isOnDark ? EditorPalette.secondaryOnDark : Color.secondary))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
    }
}

#if DEBUG
private struct PresetTilePreview: View {
    private let names = ["Natural", "Cinema", "Matte", "Vivid", "Original", "Fade", "Mono", "Warm"]

    var body: some View {
        VStack(spacing: 24) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(names, id: \.self) { name in
                        PresetTile(
                            name: name, image: nil, isSelected: name == "Natural",
                            accent: LL.amber, style: .phone, action: {})
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(width: 393)
            .padding(.vertical, 12)
            .background(EditorPalette.rgb(0x1C1C1E))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                ForEach(names, id: \.self) { name in
                    PresetTile(
                        name: name, image: nil, isSelected: name == "Cinema",
                        accent: LL.amber, style: .padGrid, action: {})
                }
            }
            .padding(16)
            .frame(width: 400)
            .background(EditorPalette.rgb(0x1C1C1E))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(names.prefix(6), id: \.self) { name in
                    PresetTile(
                        name: name, image: nil, isSelected: name == "Matte",
                        accent: LL.accent, style: .macGrid, action: {})
                }
            }
            .padding(12)
            .frame(width: 298)
            .background(Color.white)
        }
        .padding(20)
        .background(EditorPalette.rgb(0xF2F2F7))
    }
}

#Preview("Preset tiles") {
    PresetTilePreview()
}
#endif

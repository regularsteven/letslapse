import SwiftUI

// Mirrors the main-button row of boards 2a (iPhone: a black bar under the
// picture), 5a (iPad: a translucent pill bottom-right) and 3b (Mac: a white
// card at the top of the rail) — spec §4 per-platform layout.

/// The six main buttons — Presets · Light · Color · Effects · Detail · Crop.
///
/// One row, three dressings. The cells are the same everywhere (icon, label,
/// a 4 pt dot); what changes is their size and the surface they sit on: the
/// phone's bar is flush black under the picture, the iPad's is a floating pill
/// over it, the Mac's a card in the rail. Tapping a group opens its panel;
/// tapping the open group again leaves it open — closing is the panel's ✓/✕,
/// so a stray second tap can never throw an edit away.
///
/// The dot is the header dot's rule, per group: filled with the accent when
/// the group holds a non-neutral value (or a field that travels), clear
/// otherwise. It is drawn clear rather than removed so the cells never change
/// height as values come and go.
struct EditorGroupBar: View {
    @Binding var selection: EditorGroup?
    /// The groups whose dot is lit.
    var nonNeutral: Set<EditorGroup>
    var style: Style
    /// `LL.amber` on the dark editors, `LL.accent` on the Mac.
    var accent: Color

    enum Style {
        /// 2a: six 58 pt cells spread across a black bar.
        case phone
        /// 5a: the same cells packed into a translucent pill.
        case padPill
        /// 3b: six 46 pt cells in a white rail card.
        case macCard
    }

    // MARK: - Metrics

    private var cellWidth: CGFloat { style == .macCard ? 46 : 58 }
    private var iconSize: CGFloat { style == .macCard ? 18 : 20 }
    private var labelSize: CGFloat { style == .macCard ? 9.5 : 10 }
    private var cellRadius: CGFloat {
        switch style {
        case .phone: return 22
        case .padPill: return 20
        case .macCard: return 12
        }
    }
    private var cellPaddingTop: CGFloat { style == .macCard ? 6 : 7 }
    private var cellPaddingBottom: CGFloat { style == .macCard ? 4 : 5 }
    /// `#8E8E93` on the dark surfaces, `#6D6D72` on the Mac card — which
    /// adapts to a dark window, and to the iPhone's forced-dark rail.
    private var idle: Color {
        style == .macCard ? EditorPalette.secondaryOnLight : EditorPalette.secondaryOnDark
    }
    private var selectedFill: Double { style == .macCard ? 0.12 : 0.14 }

    var body: some View {
        switch style {
        case .phone:
            spread
                .padding(.top, 8)
                .padding(.horizontal, 10)
                .background(Color.black)
        case .padPill:
            HStack(spacing: 4) {
                ForEach(EditorGroup.allCases) { cell($0) }
            }
            .padding(6)
            .background(
                EditorPalette.rgb(0x1C1C1E).opacity(0.85),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        case .macCard:
            spread
                .padding(6)
                .llCard(cornerRadius: 12)
        }
    }

    /// The phone and Mac rows: first cell at the leading edge, last at the
    /// trailing edge, equal gaps between — CSS's space-between.
    private var spread: some View {
        HStack(spacing: 0) {
            ForEach(Array(EditorGroup.allCases.enumerated()), id: \.element) { index, group in
                if index > 0 { Spacer(minLength: 0) }
                cell(group)
            }
        }
    }

    private func cell(_ group: EditorGroup) -> some View {
        let selected = selection == group
        return Button {
            // No toggle-off: the open panel's ✓/✕ own closing.
            selection = group
        } label: {
            VStack(spacing: 3) {
                Image(systemName: group.systemImage)
                    .font(.system(size: iconSize, weight: .regular))
                    .frame(height: iconSize)
                Text(group.title)
                    .font(.system(size: labelSize, weight: .semibold))
                    .lineLimit(1)
                Circle()
                    .fill(nonNeutral.contains(group) ? accent : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .foregroundStyle(selected ? accent : idle)
            .frame(width: cellWidth)
            .padding(.top, cellPaddingTop)
            .padding(.bottom, cellPaddingBottom)
            .background(
                RoundedRectangle(cornerRadius: cellRadius, style: .continuous)
                    .fill(selected ? accent.opacity(selectedFill) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: cellRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.title)
        .accessibilityValue(nonNeutral.contains(group) ? "adjusted" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

#if DEBUG
private struct EditorGroupBarPreview: View {
    @State private var phone: EditorGroup? = .light
    @State private var pad: EditorGroup? = .color
    @State private var mac: EditorGroup? = .effects

    var body: some View {
        VStack(spacing: 24) {
            EditorGroupBar(selection: $phone, nonNeutral: [.light, .color], style: .phone, accent: LL.amber)
                .frame(width: 393)
            EditorGroupBar(selection: $pad, nonNeutral: [.color], style: .padPill, accent: LL.amber)
                .padding(16)
                .background(Color(red: 0.2, green: 0.25, blue: 0.3))
            EditorGroupBar(selection: $mac, nonNeutral: [.effects, .crop], style: .macCard, accent: LL.accent)
                .frame(width: 298)
                .padding(16)
                .background(EditorPalette.rgb(0xF2F2F7))
        }
        .padding(20)
        .background(Color.black)
    }
}

#Preview("Group bar") {
    EditorGroupBarPreview()
}
#endif

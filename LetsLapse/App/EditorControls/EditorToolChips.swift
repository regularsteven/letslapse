import SwiftUI

// Mirrors the tool-chip row of boards 2a / 5a (dark chips, 20 pt icons) and
// 3b (light Mac chips, 18 pt icons) — spec §1 chip labels, §5 treatment 1e-A
// for the diamond.

/// A group's row of tool chips — `Exp · Con` · `High · Wh` · `Shad · Bl`.
///
/// One row, every chip the same width, so a three-tool group and a two-tool
/// group both fill the panel edge to edge and the row never scrolls. The
/// selected chip is the one whose pad (or slider) is showing below; the
/// selection persists per group within the session, which is the panel's
/// business — the row only reports taps.
///
/// The 7 pt diamond after the label marks a tool either of whose fields
/// travels over the clip (treatment 1e-A), the same mark the pad readouts
/// carry beside the travelling field itself.
struct EditorToolChips: View {
    var tools: [EditorTool]
    @Binding var selection: EditorTool?
    /// Tools with a keyframed field — shown with the diamond.
    var keyframed: Set<EditorTool>
    var style: XYPadStyle
    /// `LL.amber` on the dark editors, `LL.accent` on the Mac.
    var accent: Color

    // MARK: - Metrics

    private var iconSize: CGFloat { style == .dark ? 20 : 18 }
    private var labelSize: CGFloat { style == .dark ? 11.5 : 11 }
    private var paddingVertical: CGFloat { style == .dark ? 7 : 6 }
    private var cornerRadius: CGFloat { style == .dark ? 12 : 9 }
    private var iconGap: CGFloat { style == .dark ? 6 : 5 }
    /// White on the dark editors; the Mac's `#1C1C1E` is the primary label
    /// in a light window, which is what lets a dark window read too.
    private var ink: Color { style == .dark ? .white : .primary }
    private var idleFill: Color {
        style == .dark ? Color.white.opacity(0.08) : EditorPalette.chipFillOnLight
    }
    private var selectedFill: Color {
        accent.opacity(style == .dark ? 0.16 : 0.12)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tools) { chip($0) }
        }
    }

    private func chip(_ tool: EditorTool) -> some View {
        let selected = selection == tool
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Button {
            selection = tool
        } label: {
            HStack(spacing: iconGap) {
                // The icon keeps its ink when selected — on the board it is a
                // fixed SVG; only the label takes the accent.
                EditorToolIcon(glyph: .tool(tool), ink: ink, size: iconSize)
                // At the Mac's 330 pt rail three chips get ~87 pt each, which
                // "Exp · Con" plus its icon and diamond overruns by a few
                // points: the label shrinks a little before it ever
                // truncates, so a keyframed row still reads as words.
                Text(tool.shortLabel)
                    .font(.system(size: labelSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                if keyframed.contains(tool) { KeyframeDiamond() }
            }
            .foregroundStyle(selected ? accent : ink)
            .padding(.vertical, paddingVertical)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(shape.fill(selected ? selectedFill : idleFill))
            .overlay(shape.strokeBorder(selected ? accent : Color.clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(keyframed.contains(tool) ? "\(tool.title), keyframed" : tool.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

#if DEBUG
private struct EditorToolChipsPreview: View {
    @State private var light: EditorTool? = .expCon
    @State private var color: EditorTool? = .whiteBalance
    @State private var effects: EditorTool? = .vignette
    @State private var detail: EditorTool? = .noise

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                EditorToolChips(
                    tools: EditorGroup.light.tools, selection: $light,
                    keyframed: [.expCon, .highWhites], style: .dark, accent: LL.amber)
                EditorToolChips(
                    tools: EditorGroup.color.tools, selection: $color,
                    keyframed: [.whiteBalance], style: .dark, accent: LL.amber)
                EditorToolChips(
                    tools: EditorGroup.effects.tools, selection: $effects,
                    keyframed: [], style: .dark, accent: LL.amber)
            }
            .padding(16)
            .frame(width: 393)
            .background(EditorPalette.rgb(0x1C1C1E))

            VStack(spacing: 10) {
                EditorToolChips(
                    tools: EditorGroup.light.tools, selection: $light,
                    keyframed: [.expCon], style: .light, accent: LL.accent)
                EditorToolChips(
                    tools: EditorGroup.detail.tools, selection: $detail,
                    keyframed: [], style: .light, accent: LL.accent)
            }
            .padding(12)
            .frame(width: 298)
            .background(Color.white)
        }
        .padding(20)
        .background(EditorPalette.rgb(0xF2F2F7))
    }
}

#Preview("Tool chips") {
    EditorToolChipsPreview()
}
#endif

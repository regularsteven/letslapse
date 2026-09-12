import SwiftUI

// Mirrors the Editor / Text / Masks pill floating top-right over the picture
// on boards 2a (iPhone) and 5a (iPad) — spec §4 and decision 6: the rail's
// tab bar moves over the picture on the touch editors; the Mac keeps
// `RailTabBar` in its rail.

/// The over-picture tab switcher — the same `RailTab` selection the rail's
/// `RailTabBar` drives, dressed as a translucent pill so it can sit on the
/// photograph without a rail behind it.
///
/// Amber on ink rather than the rail's accent-on-card, because it floats over
/// whatever the picture happens to be: the ink ground gives the amber a
/// constant contrast, and the material behind it keeps the picture faintly
/// legible so the pill reads as chrome, not as a hole.
struct EditorTabPill: View {
    @Binding var selection: RailTab
    var tabs: [RailTab]
    /// `LL.amber` on the dark editors.
    var accent: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                segment(tab)
            }
        }
        .padding(3)
        .background(
            EditorPalette.rgb(0x1C1C1E).opacity(0.85),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func segment(_ tab: RailTab) -> some View {
        let selected = selection == tab
        return Button {
            guard !selected else { return }
            // The same beat as `RailTabBar`, so switching feels like one
            // control wherever it lives.
            withAnimation(.easeInOut(duration: 0.18)) { selection = tab }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.black : accent)
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(selected ? accent : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel("\(tab.rawValue) controls")
    }
}

#if DEBUG
private struct EditorTabPillPreview: View {
    @State private var tab: RailTab = .editor

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [.orange, .pink, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: 393, height: 200)
            EditorTabPill(selection: $tab, tabs: [.editor, .text, .masks], accent: LL.amber)
                .padding(16)
        }
    }
}

#Preview("Tab pill") {
    EditorTabPillPreview()
}
#endif

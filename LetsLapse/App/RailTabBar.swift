import SwiftUI

/// The editor rail's pages. The rail used to be one long stack; presets
/// and sliders are the everyday work, text overlays and frame management are
/// occasional, and stacking all three meant the occasional buried the daily.
///
/// Masks is a fourth page rather than a card inside Text because its
/// contents belong to the PROJECT, not to a layer: every text layer can pick
/// any of the project's regions, so the place to author them cannot live
/// inside one layer's disclosure.
enum RailTab: String, CaseIterable, Identifiable {
    case editor = "Editor"
    case text = "Text"
    case frames = "Frames"
    case masks = "Masks"
    var id: String { rawValue }
}

/// The switcher pinned above the rail's scroll view — the Ken Burns segment
/// control's visual language (capsule segments in a capsule card track), sized
/// up and stretched because this bar owns the rail's full width rather than a
/// corner of a header.
struct RailTabBar: View {
    @Binding var selection: RailTab
    let tabs: [RailTab]
    var accent: Color = LL.accent
    /// Label color over the selected fill — black on the editors' amber, white
    /// on the Mac's accent, the same pair the preset chips use.
    var onAccent: Color = .white

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                segment(tab)
            }
        }
        .padding(3)
        .background(Capsule().fill(LL.cardBackground))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
    }

    private func segment(_ tab: RailTab) -> some View {
        let selected = selection == tab
        return Button {
            guard !selected else { return }
            withAnimation(.easeInOut(duration: 0.18)) { selection = tab }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? onAccent : accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Capsule().fill(selected ? accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel("\(tab.rawValue) controls")
    }
}

import SwiftUI

/// The editor rail's pages. The rail used to be one long stack; presets
/// and sliders are the everyday work, text overlays and frame management are
/// occasional, and stacking all three meant the occasional buried the daily.
///
/// Regions is a fourth page rather than a card inside Text because its
/// contents belong to the PROJECT, not to a layer: every text layer can pick
/// any of the project's regions, so the place to author them cannot live
/// inside one layer's disclosure.
///
/// The page is called **Regions** on screen (2026-10-16, Steven's consistency
/// audit): it holds the project's masks AND its shapes, and "Masks" named
/// half of it. The case and its raw value keep the old word so every hook
/// (`LL_RAIL=masks`, `LL_ITEM=<id>:masks`, `LL_PREVIEW_PROMPT=masks`) and
/// every log line still answer — `init(hook:)` takes `regions` as well.
enum RailTab: String, CaseIterable, Identifiable {
    case editor = "Editor"
    case text = "Text"
    case frames = "Frames"
    case masks = "Masks"
    var id: String { rawValue }

    /// What the pill and the rail print.
    var title: String {
        self == .masks ? "Regions" : rawValue
    }

    /// The seat's text: the title, with `*` after it on a page that holds
    /// work of the project's own.
    func label(marked: Bool) -> String {
        marked ? title + "*" : title
    }

    /// A hook's page word, in either name: `masks` and `regions` are the
    /// same page.
    init?(hook: String) {
        let word = hook.lowercased()
        if word == "regions" {
            self = .masks
        } else if let tab = RailTab.allCases.first(where: { $0.rawValue.lowercased() == word }) {
            self = tab
        } else {
            return nil
        }
    }
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
    /// Pages drawn greyed in place — they need the originals (`EditorPreviewPage`).
    /// A tap still reaches the selection, whose owner asks whether to fetch them.
    var locked: Set<RailTab> = []
    /// Pages that hold work of this project's own — printed with a trailing
    /// `*` (Regions once a mask or a shape exists), so the pill says where
    /// something has been done without being opened.
    var marked: Set<RailTab> = []

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
            Text(tab.label(marked: marked.contains(tab)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? onAccent : locked.contains(tab) ? accent.opacity(0.38) : accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Capsule().fill(selected ? accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel("\(tab.title) controls")
        .accessibilityValue(marked.contains(tab) ? "has work" : "")
        .accessibilityHint(locked.contains(tab) ? "Needs the originals" : "")
    }
}

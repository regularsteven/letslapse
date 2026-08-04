import SwiftUI

// MARK: - Palette

/// The redesign's shared look: burnt-orange accent, amber highlights, grouped
/// backgrounds, and soft white cards.
enum LL {
    static let accent = Color(red: 195 / 255, green: 106 / 255, blue: 0)
    static let accentDeep = Color(red: 138 / 255, green: 74 / 255, blue: 0)
    static let amber = Color(red: 255 / 255, green: 179 / 255, blue: 64 / 255)
    static let ink = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)

    static var screenBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }

    static var cardBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var hairline: Color {
        Color.primary.opacity(0.08)
    }
}

// MARK: - Speed math

/// One vocabulary everywhere: "speed" is the number of real frames averaged
/// into one output frame. The number that matters to people — how long the
/// clip will be — is derived from it in one place so every screen agrees.
enum SpeedMath {
    static let presets = [10, 25, 50, 100]
    static let range = 1...240

    /// The output-ruler stepper's detents. A custom value set through the
    /// fine-grained sheet steps to its nearest neighbour from here.
    static let stepDetents = [1, 2, 4, 8, 12, 16, 25, 50, 100, 150, 200]

    /// The next detent from `current` in `direction` (+1 / −1). A value between
    /// detents moves to the adjacent detent on that side, so 37× steps down to
    /// 25× and up to 50×.
    static func detent(from current: Int, direction: Int) -> Int {
        if direction > 0 {
            return stepDetents.first { $0 > current } ?? max(current, stepDetents.last ?? current)
        }
        if direction < 0 {
            return stepDetents.last { $0 < current } ?? min(current, stepDetents.first ?? current)
        }
        return current
    }

    /// Output clip length for a known number of source frames.
    static func outputSeconds(inputFrames: Double, speed: Int, outputFPS: Int) -> Double {
        guard inputFrames > 0, speed > 0, outputFPS > 0 else { return 0 }
        return inputFrames / Double(speed) / Double(outputFPS)
    }

    /// Output clip length for a recording of `recordSeconds` at `captureFPS`.
    static func outputSeconds(
        recordSeconds: Double,
        captureFPS: Double,
        speed: Int,
        outputFPS: Int
    ) -> Double {
        outputSeconds(
            inputFrames: max(0, recordSeconds) * max(1, captureFPS),
            speed: speed,
            outputFPS: outputFPS
        )
    }

    /// How long to record to end up with a clip of `clipSeconds`.
    static func recordSeconds(
        clipSeconds: Double,
        speed: Int,
        captureFPS: Double,
        outputFPS: Int
    ) -> Double {
        guard captureFPS > 0 else { return 0 }
        return clipSeconds * Double(speed) * Double(outputFPS) / captureFPS
    }

    /// "2.2 s", "22 s", "1:12 min"
    static func clipLength(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 9.95 { return String(format: "%.1f s", seconds) }
        if seconds < 60 { return String(format: "%.0f s", seconds) }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d min", whole / 60, whole % 60)
    }

    /// Chip-sized variant: "2.2s", "22s", "1:12"
    static func clipLengthCompact(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 9.95 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The character word shown on preset chips.
    static func chipWord(for speed: Int) -> String {
        switch speed {
        case ..<5: return "gentle"
        case 5..<18: return "subtle"
        case 18..<40: return "smooth"
        case 40..<80: return "flowing"
        case 80..<160: return "streaks"
        default: return "trails"
        }
    }

    /// The fuller phrase used on the estimate card.
    static func cardPhrase(for speed: Int) -> String {
        switch speed {
        case ..<5: return "gentle motion"
        case 5..<18: return "subtle blur"
        case 18..<40: return "smooth motion"
        case 40..<80: return "flowing blur"
        case 80..<160: return "heavy streaks"
        default: return "light trails"
        }
    }
}

// MARK: - Formatting

enum LLFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

// MARK: - Buttons

struct LLPrimaryButtonStyle: ButtonStyle {
    var tint: Color = LL.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                tint.opacity(configuration.isPressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct LLSecondaryButtonStyle: ButtonStyle {
    var tint: Color = LL.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                LL.cardBackground.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Cards & headers

struct LLCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(
                LL.cardBackground,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
    }
}

extension View {
    func llCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(LLCardModifier(cornerRadius: cornerRadius))
    }
}

struct LLSectionHeader: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// A settings-style row inside a card stack.
struct LLRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var titleColor: Color = .primary
    var showsDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundStyle(titleColor)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if showsDivider {
                Divider()
                    .padding(.leading, 16)
            }
        }
    }
}

// MARK: - Tabs

enum LLTab: String, CaseIterable, Identifiable {
    case create
    case gallery
    case projects
    case collections
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .create: return "Create"
        case .gallery: return "Gallery"
        case .projects: return "Projects"
        case .collections: return "Collections"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .create: return "record.circle"
        case .gallery: return "photo.on.rectangle.angled"
        case .projects: return "square.stack"
        case .collections: return "film.stack"
        case .settings: return "line.3.horizontal"
        }
    }
}

/// The floating pill tab bar from the redesign. Content scrolls behind it.
/// Tapping the already-selected tab reports a reselect instead, so the owner
/// can pop that tab back to its root.
struct FloatingTabBar: View {
    @Binding var selection: LLTab
    var onReselect: (LLTab) -> Void = { _ in }

    /// Derived from the tab count rather than fixed: five tabs at the original
    /// 92pt would make a 488pt pill, wider than a 393pt iPhone. 66pt keeps the
    /// bar at 358pt with room either side, and still fits "Projects" at 10.5pt.
    private var tabWidth: CGFloat {
        LLTab.allCases.count > 4 ? 66 : 92
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(LLTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    if isSelected {
                        onReselect(tab)
                    } else {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 17))
                        Text(tab.title)
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(isSelected ? LL.accent : Color.secondary)
                    .frame(width: tabWidth)
                    .padding(.vertical, 7)
                    .background(
                        isSelected ? LL.accent.opacity(0.12) : Color.clear,
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(LL.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 15, y: 8)
    }
}

// MARK: - Small shared pieces

/// The five canvas-ratio chips — one control for a collection's CANVAS row
/// and the Adjust screen's clip canvas.
struct CanvasRatioChips: View {
    var selected: CanvasRatio?
    var isEnabled = true
    var onSelect: (CanvasRatio) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CanvasRatio.allCases) { ratio in
                let isSelected = selected == ratio
                Button {
                    guard isEnabled else { return }
                    onSelect(ratio)
                } label: {
                    Text(ratio.rawValue)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(
                            isSelected ? .white
                                : (isEnabled ? Color.primary : Color.secondary.opacity(0.5)))
                        .padding(.horizontal, 13)
                        .frame(height: 33)
                        .background(
                            isSelected ? LL.accent : LL.cardBackground,
                            in: Capsule())
                        .shadow(color: .black.opacity(isSelected ? 0 : 0.06), radius: 1.5, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Canvas \(ratio.rawValue)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// Translucent dark chip used over camera/video imagery.
struct MediaBadge: View {
    var text: String
    var tint: Color = .white

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.black.opacity(0.5), in: Capsule())
    }
}

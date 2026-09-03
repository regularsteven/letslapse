import SwiftUI
import LetsLapseKit

// The Light Ladder's shared pieces: the rung palette and swatch, the armed
// light panel and its collapsed pill, the running rail and toast, and the
// picker sheet. The list, editor and rung screens are in
// `LightLaddersView.swift`. Design: Claude Design handoff "Light Ladder",
// Turn 2 (2a, 2f); `docs/light-ladder.md` §6.

// MARK: - Palette

/// Four `LL` tokens for four rungs, brightest first — amber, accent, deep
/// accent, ink — and a nearest-stop mapping for ladders of any other length,
/// so Sunrise reads as Sunset inverted with no extra copy.
enum LadderPalette {
    static let stops: [Color] = [LL.amber, LL.accent, LL.accentDeep, LL.ink]

    /// The colour of rung `index` in a ladder of `count`.
    static func color(rung index: Int, of count: Int) -> Color {
        guard count > 1 else { return stops[0] }
        let position = Double(index) / Double(count - 1)
        let slot = Int((position * Double(stops.count - 1)).rounded())
        return stops[min(max(slot, 0), stops.count - 1)]
    }

    /// The ladder as a vertical gradient, brightest at the top.
    static func gradient(for ladder: LightLadder) -> LinearGradient {
        let count = max(ladder.rungs.count, 1)
        let colors = (0..<count).map { color(rung: $0, of: count) }
        return LinearGradient(colors: colors.count == 1 ? [colors[0], colors[0]] : colors,
                              startPoint: .top, endPoint: .bottom)
    }
}

/// The 26 pt rounded swatch on list rows.
struct LadderSwatch: View {
    let ladder: LightLadder
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LadderPalette.gradient(for: ladder))
            .frame(width: size, height: size)
    }
}

// MARK: - The light panel (armed)

/// An overlay on the viewfinder, not part of the control stack: the smoothed
/// scene EV, the rung it selects, what that costs, and which rung comes
/// next. Closable — it collapses to `LadderRungPill` rather than vanishing,
/// so the shoot never stops naming its state.
struct LadderLightPanel: View {
    let ladder: LightLadder
    let rungIndex: Int
    let sceneEV: Double?
    /// The actuation clamp the light panel states at arm, e.g.
    /// "blend 10 → 6 in RAW on this camera". Nil when the rung runs as asked.
    let clampNote: String?
    let onClose: () -> Void

    private var rung: Rung { ladder.rungs[rungIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LadderPalette.color(rung: rungIndex, of: ladder.rungs.count))
                    .frame(width: 9, height: 9)
                Text(rung.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let sceneEV {
                    Text(String(format: "scene EV %.1f", sceneEV))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close light panel")
            }
            Text(leverLine)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
            Text(costLine)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.6))
            if let clampNote {
                Text(clampNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LL.amber)
            }
            if let next = nextLine {
                Text(next)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LL.amber)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var leverLine: String {
        "every \(LightLadderFormat.seconds(rung.intervalSeconds)) · \(rung.blendSummary) · ISO \(rung.iso.summary) · shutter \(rung.shutter.summary)"
    }

    private var costLine: String {
        let perHour = Int((3600 / max(rung.intervalSeconds, 0.1)).rounded())
        let frames = perHour >= 1000
            ? String(format: "≈%@ frames an hour", Self.grouped(perHour))
            : "≈\(perHour) frames an hour"
        let look = rung.blendFrames > 1
            ? "motion softened by \(rung.blendFrames)-frame stacking"
            : "single frames, no stacking"
        return "\(frames) · \(look)"
    }

    private var nextLine: String? {
        guard rungIndex + 1 < ladder.rungs.count, let threshold = rung.lowerBoundEV else { return nil }
        let next = ladder.rungs[rungIndex + 1]
        let look = next.blendFrames > 1 ? "blend \(next.blendFrames)" : "no stacking"
        return "\(next.name) is next, below EV \(LightLadderFormat.ev(threshold)) — shutter \(next.shutter.summary), \(look)"
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// The panel's collapsed form: the rung's swatch and name, tapping back open.
struct LadderRungPill: View {
    let name: String
    let color: Color
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.black.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open light panel, \(name)")
    }
}

// MARK: - Running: the rail and the toast

/// Over the viewfinder like the Scanner overlay: one bar per rung, heights
/// proportional to EV span, the active one widened to 22 pt and ringed in
/// amber, its name in a chip beside it.
struct LadderRail: View {
    let state: CameraController.LadderState

    private static let totalHeight: CGFloat = 180

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(state.rungName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LL.amber)
                .lineLimit(1)
                .frame(maxWidth: 90)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(spacing: 5) {
                ForEach(Array(state.spans.enumerated()), id: \.offset) { index, span in
                    let active = index == state.rungIndex
                    let total = max(state.spans.reduce(0, +), 1)
                    let height = max(CGFloat(span / total) * Self.totalHeight, 14)
                    RoundedRectangle(cornerRadius: active ? 11 : 7, style: .continuous)
                        .fill(LadderPalette.color(rung: index, of: state.spans.count))
                        .opacity(active ? 1 : (index == state.spans.count - 1 ? 0.6 : 0.3))
                        .frame(width: active ? 22 : 14, height: height)
                        .overlay {
                            if active {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(LL.amber, lineWidth: 2)
                            } else if index == state.spans.count - 1 {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            }
                        }
                }
            }
            .padding(.vertical, 8)
            .frame(width: 34)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .animation(.easeInOut(duration: 0.25), value: state.rungIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ladder rung \(state.rungName)")
    }
}

/// "Stepped down to Dusk" — a brief toast on a rung change, with the ladder
/// glyph, its active line amber.
struct LadderToast: View {
    let state: CameraController.LadderState
    let steppedDown: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 1.5) {
                ForEach(0..<max(state.rungNames.count, 1), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index == state.rungIndex ? LL.amber : Color.white.opacity(0.3))
                        .frame(width: 11, height: 1.8)
                }
            }
            Text("Stepped \(steppedDown ? "down" : "up") to \(state.rungName)")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.black.opacity(0.65), in: Capsule())
        .accessibilityLabel("Stepped \(steppedDown ? "down" : "up") to \(state.rungName)")
    }
}

// MARK: - The picker

/// Choosing is one tap; managing is a deliberate second one. The sheet never
/// edits: the built-in first with a check on the selected ladder, then the
/// user's, and Manage opens Interval ladders.
struct LadderPickerSheet: View {
    @ObservedObject var store: LightLadderStore
    @Binding var selectedID: UUID?
    let onManage: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ladder")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button("Manage") { onManage() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LL.amber)
            }
            .padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(store.ladders.enumerated()), id: \.element.id) { index, ladder in
                    Button {
                        selectedID = ladder.isBuiltIn ? nil : ladder.id
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            LadderSwatch(ladder: ladder)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ladder.name)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(subtitle(for: ladder))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if isSelected(ladder) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(LL.amber)
                            }
                        }
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < store.ladders.count - 1 {
                        Divider().padding(.leading, 38)
                    }
                }
            }
            Text("Manage opens Interval ladders, where a ladder can be duplicated, edited or deleted. Picking one here only arms it.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func isSelected(_ ladder: LightLadder) -> Bool {
        store.resolve(id: selectedID).id == ladder.id
    }

    private func subtitle(for ladder: LightLadder) -> String {
        ladder.isBuiltIn ? "Built in · \(ladder.thresholdSummary)" : ladder.thresholdSummary
    }
}

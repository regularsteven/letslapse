import SwiftUI

/// The manual grade's controls — Lightroom-basic-panel parity, grouped the way
/// Lightroom groups them: White Balance, Light, Color, Effects.
///
/// Shared by both editors — `PhotoViewerView` (photo and interval captures) and
/// `VideoEditorView` — so the surfaces can't drift apart. It owns no render
/// state: the binding's owner decides how often to re-render and when to write
/// the values back to the project.
///
/// Two layouts: `alwaysExpanded` (the macOS rail, wide viewers) shows every
/// section open under plain headers; the stacked phone layout collapses each
/// section into its own card, Light open by default, with an accent dot marking
/// sections that hold a non-neutral value.
struct PhotoAdjustmentsPanel: View {
    @Binding var adjustments: PhotoAdjustments
    var alwaysExpanded: Bool = false
    /// The as-shot anchor for the temperature readout and the white-balance
    /// quick-picks. D65 when the file declares nothing.
    var asShotKelvin: Double = 6500
    /// The highlight colour for active values, tints and reset affordances.
    /// Defaults to the app accent, which is what the light macOS rail wants; the
    /// always-dark iOS editors pass `LL.amber` instead, per the design system's
    /// "highlights over dark" rule.
    var accent: Color = LL.accent

    enum PanelSection: String, CaseIterable, Identifiable {
        case whiteBalance = "White Balance"
        case light = "Light"
        case color = "Color"
        case effects = "Effects"
        var id: String { rawValue }
    }

    @State private var openSections: Set<PanelSection> = [.light]

    var body: some View {
        Group {
            if alwaysExpanded {
                VStack(spacing: 14) {
                    ForEach(PanelSection.allCases) { section in
                        VStack(spacing: 10) {
                            header(for: section, collapsible: false)
                            content(for: section)
                        }
                    }
                    resetAllButton
                }
                .padding(14)
                .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(PanelSection.allCases) { section in
                        VStack(spacing: 10) {
                            header(for: section, collapsible: true)
                            if openSections.contains(section) {
                                content(for: section)
                            }
                        }
                        .padding(12)
                        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    resetAllButton
                        .padding(.horizontal, 2)
                }
                .onAppear(perform: applySectionHook)
            }
        }
    }

    // MARK: - Sections

    private func header(for section: PanelSection, collapsible: Bool) -> some View {
        HStack(spacing: 6) {
            Text(section.rawValue)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.secondary)
            if !isNeutral(section) {
                Circle().fill(accent).frame(width: 6, height: 6)
            }
            Spacer()
            if !isNeutral(section) {
                Button("Reset") { reset(section) }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                    .buttonStyle(.plain)
            }
            if collapsible {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(openSections.contains(section) ? 0 : -90))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard collapsible else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                if openSections.contains(section) {
                    openSections.remove(section)
                } else {
                    openSections.insert(section)
                }
            }
        }
    }

    @ViewBuilder private func content(for section: PanelSection) -> some View {
        switch section {
        case .whiteBalance:
            whiteBalanceMenu
            slider("Temp", value: $adjustments.temperature,
                   range: PhotoAdjustments.temperatureRange, readout: kelvinReadout)
            slider("Tint", value: $adjustments.tint,
                   range: PhotoAdjustments.tintRange)
        case .light:
            slider("Exposure", value: $adjustments.exposure,
                   range: PhotoAdjustments.exposureRange, readout: exposureReadout)
            slider("Contrast", value: $adjustments.contrast,
                   range: PhotoAdjustments.contrastRange)
            slider("Highlights", value: $adjustments.highlights,
                   range: PhotoAdjustments.highlightsRange)
            slider("Shadows", value: $adjustments.shadows,
                   range: PhotoAdjustments.shadowsRange)
            slider("Whites", value: $adjustments.whites,
                   range: PhotoAdjustments.whitesRange)
            slider("Blacks", value: $adjustments.blacks,
                   range: PhotoAdjustments.blacksRange)
        case .color:
            slider("Vibrance", value: $adjustments.vibrance,
                   range: PhotoAdjustments.vibranceRange)
            slider("Saturation", value: $adjustments.saturation,
                   range: PhotoAdjustments.saturationRange)
        case .effects:
            slider("Clarity", value: $adjustments.clarity,
                   range: PhotoAdjustments.clarityRange)
            slider("Vignette", value: $adjustments.vignetteIntensity,
                   range: PhotoAdjustments.vignetteRange)
        }
    }

    private var resetAllButton: some View {
        Button("Reset adjustments") {
            adjustments = .neutral
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(adjustments.isNeutral ? .secondary : accent)
        .buttonStyle(.plain)
        .disabled(adjustments.isNeutral)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    // MARK: - White balance quick-picks

    /// The old picker's presets, now slider-setters: each declares an
    /// illuminant against the file's as-shot anchor, exactly like Lightroom's
    /// WB dropdown. The menu shows "Custom" whenever the sliders don't match
    /// any pick.
    private var whiteBalanceMenu: some View {
        HStack {
            Text("White Bal.")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
            Spacer()
            Menu(currentQuickPickName) {
                Button("As Shot") { setWhiteBalance(offset: 0) }
                Button("Sunny") { setWhiteBalance(kelvin: 5500) }
                Button("Cloudy") { setWhiteBalance(kelvin: 6500) }
                Button("Fluorescent") { setWhiteBalance(kelvin: 4000) }
                Button("Tungsten") { setWhiteBalance(kelvin: 3200) }
            }
            .font(.system(size: 13, weight: .semibold))
            .tint(accent)
        }
    }

    private var asShotMired: Double { 1_000_000 / min(max(asShotKelvin, 1667), 25000) }

    private func offsetDeclaring(kelvin: Double) -> Float {
        let offset = Float(asShotMired - 1_000_000 / kelvin)
        return min(max(offset, PhotoAdjustments.temperatureRange.lowerBound),
                   PhotoAdjustments.temperatureRange.upperBound)
    }

    private func setWhiteBalance(kelvin: Double) {
        setWhiteBalance(offset: offsetDeclaring(kelvin: kelvin))
    }

    private func setWhiteBalance(offset: Float) {
        adjustments.temperature = offset
        adjustments.tint = 0
    }

    private var currentQuickPickName: String {
        guard adjustments.tint == 0 else { return "Custom" }
        if adjustments.temperature == 0 { return "As Shot" }
        let picks: [(String, Double)] = [
            ("Sunny", 5500), ("Cloudy", 6500), ("Fluorescent", 4000), ("Tungsten", 3200),
        ]
        for (name, kelvin) in picks
        where abs(adjustments.temperature - offsetDeclaring(kelvin: kelvin)) < 0.5 {
            return name
        }
        return "Custom"
    }

    // MARK: - Sliders

    private func slider(
        _ label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        readout: ((Float) -> String)? = nil
    ) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text((readout ?? defaultReadout)(value.wrappedValue))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(value.wrappedValue == 0 ? .secondary : .primary)
            }
            .contentShape(Rectangle())
            // Double-tap (double-click on the Mac) a label to reset just that
            // slider — the idiom every editor teaches.
            .onTapGesture(count: 2) { value.wrappedValue = 0 }
            Slider(value: value, in: range)
                .tint(accent)
                .accessibilityLabel(label)
        }
    }

    /// Slider values read as -100…100, which is the vocabulary people know
    /// from every other editor, rather than the -1…1 the engine takes.
    private func defaultReadout(_ value: Float) -> String {
        value == 0 ? "0" : String(format: "%+.0f", value * 100)
    }

    private func exposureReadout(_ value: Float) -> String {
        value == 0 ? "0" : String(format: "%+.2f", value)
    }

    private func kelvinReadout(_ value: Float) -> String {
        guard value != 0 else { return "As Shot" }
        let declaredMired = min(max(asShotMired - Double(value), 40), 600)
        return "\(Int((1_000_000 / declaredMired).rounded())) K"
    }

    // MARK: - Section state

    private func isNeutral(_ section: PanelSection) -> Bool {
        switch section {
        case .whiteBalance:
            return adjustments.temperature == 0 && adjustments.tint == 0
        case .light:
            return adjustments.exposure == 0 && adjustments.contrast == 0
                && adjustments.highlights == 0 && adjustments.shadows == 0
                && adjustments.whites == 0 && adjustments.blacks == 0
        case .color:
            return adjustments.vibrance == 0 && adjustments.saturation == 0
        case .effects:
            return adjustments.clarity == 0 && adjustments.vignetteIntensity == 0
        }
    }

    private func reset(_ section: PanelSection) {
        switch section {
        case .whiteBalance:
            adjustments.temperature = 0
            adjustments.tint = 0
        case .light:
            adjustments.exposure = 0
            adjustments.contrast = 0
            adjustments.highlights = 0
            adjustments.shadows = 0
            adjustments.whites = 0
            adjustments.blacks = 0
        case .color:
            adjustments.vibrance = 0
            adjustments.saturation = 0
        case .effects:
            adjustments.clarity = 0
            adjustments.vignetteIntensity = 0
        }
    }

    /// `LL_SECTIONS=all|wb|light|color|effects` forces the stacked layout's
    /// open state for design screenshots.
    private func applySectionHook() {
        #if DEBUG
        guard let hook = ProcessInfo.processInfo.environment["LL_SECTIONS"] else { return }
        switch hook {
        case "all": openSections = Set(PanelSection.allCases)
        case "wb": openSections = [.whiteBalance]
        case "light": openSections = [.light]
        case "color": openSections = [.color]
        case "effects": openSections = [.effects]
        default: break
        }
        #endif
    }
}

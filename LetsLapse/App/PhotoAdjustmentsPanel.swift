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
    /// The properties that travel over the shoot — marked with a diamond beside
    /// their label and an accent readout, per design treatment `1e-A`. Empty
    /// for a still, and for every clip graded with one look end to end.
    var keyframedFields: Set<PhotoAdjustmentField> = []
    /// True when the grade holds keyframes at all, so "Reset adjustments" stays
    /// live even where the moment on screen happens to read neutral.
    var hasKeyframes: Bool = false
    /// Where a double-tapped label's reset goes when the owner has a timeline
    /// to consider — zeroing the binding would write the zero into the moment
    /// under the playhead rather than taking the property back out of it.
    /// Unset (a still, or a clip with no keyframes) keeps the plain behaviour.
    var onResetField: ((PhotoAdjustmentField) -> Void)?
    /// Same, for "Reset adjustments": with keyframes there is a timeline to
    /// clear as well as values to neutralise.
    var onResetAll: (() -> Void)?
    /// Told when a control is grabbed and when it is let go. The photo editor
    /// uses it to float a 1:1 detail loupe over the picture while one of the
    /// pixel-level controls — Sharpen, Noise Reduction, Color Noise — is
    /// moving, because those are exactly the controls whose effect a
    /// fit-to-screen preview cannot show.
    var onFieldEditing: ((PhotoAdjustmentField, Bool) -> Void)?

    enum PanelSection: String, CaseIterable, Identifiable {
        case whiteBalance = "White Balance"
        case light = "Light"
        case color = "Color"
        case effects = "Effects"
        case detail = "Detail"
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
            slider("Temp", field: .temperature, readout: kelvinReadout)
            slider("Tint", field: .tint)
        case .light:
            slider("Exposure", field: .exposure, readout: exposureReadout)
            slider("Contrast", field: .contrast)
            slider("Highlights", field: .highlights)
            slider("Shadows", field: .shadows)
            slider("Whites", field: .whites)
            slider("Blacks", field: .blacks)
        case .color:
            slider("Vibrance", field: .vibrance)
            slider("Saturation", field: .saturation)
        case .effects:
            slider("Texture", field: .texture)
            slider("Clarity", field: .clarity)
            slider("Vignette", field: .vignetteIntensity)
        case .detail:
            slider("Sharpen", field: .sharpen)
            slider("Masking", field: .sharpenMasking, indented: true)
            slider("Noise Reduction", field: .noiseReduction)
            slider("Color Noise", field: .colorNoise)
            slider("Detail", field: .noiseDetail, indented: true,
                   readout: unsignedReadout)
            slider("Color Noise", field: .colorNoiseReduction)
        }
    }

    private var canReset: Bool { !adjustments.isNeutral || hasKeyframes }

    private var resetAllButton: some View {
        Button("Reset adjustments") {
            if let onResetAll {
                onResetAll()
            } else {
                adjustments = .neutral
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(canReset ? accent : .secondary)
        .buttonStyle(.plain)
        .disabled(!canReset)
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

    /// One control. `indented` marks a sub-slider — a control that qualifies
    /// the one above it rather than standing on its own (Masking under
    /// Sharpen, Detail under Noise Reduction), so it steps in and drops a
    /// point of type size instead of claiming a row of its own.
    private func slider(
        _ label: String,
        field: PhotoAdjustmentField,
        indented: Bool = false,
        readout: ((Float) -> String)? = nil
    ) -> some View {
        let value = $adjustments[dynamicMember: field.keyPath]
        let isKeyframed = keyframedFields.contains(field)
        let neutral = field.neutralValue
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: indented ? 12.5 : 13.5))
                    .foregroundStyle(.secondary)
                if isKeyframed { keyframeDiamond }
                Spacer()
                Text((readout ?? defaultReadout)(value.wrappedValue))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(readoutStyle(
                        value.wrappedValue, neutral: neutral, isKeyframed: isKeyframed))
            }
            .contentShape(Rectangle())
            // Double-tap (double-click on the Mac) a label to reset just that
            // slider — the idiom every editor teaches. With a timeline in play
            // it is the owner's business: the value here belongs to a moment,
            // and taking a property out of that moment can retire it entirely.
            .onTapGesture(count: 2) {
                if let onResetField {
                    onResetField(field)
                } else {
                    value.wrappedValue = neutral
                }
            }
            Slider(value: value, in: field.range) { editing in
                onFieldEditing?(field, editing)
            }
                .tint(accent)
                .accessibilityLabel(isKeyframed ? "\(label), keyframed" : label)
        }
        .padding(.leading, indented ? 14 : 0)
    }

    private func readoutStyle(_ value: Float, neutral: Float, isKeyframed: Bool) -> Color {
        // Accent whenever the property travels — the readout is then a value at
        // *this moment*, not a value for the clip, and that is worth saying
        // even when the number under the playhead happens to be neutral.
        if isKeyframed { return accent }
        return value == neutral ? Color.secondary : Color.primary
    }

    /// Treatment `1e-A`: the smallest new mark that could carry the idea, and
    /// the one that composes with the accent dots the section headers already
    /// use. A dot means "non-neutral"; a diamond means "varies over time".
    private var keyframeDiamond: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(LL.amber)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .strokeBorder(LL.accent, lineWidth: 1))
            .frame(width: 7, height: 7)
            .rotationEffect(.degrees(45))
            .accessibilityHidden(true)
    }

    /// Slider values read as -100…100, which is the vocabulary people know
    /// from every other editor, rather than the -1…1 the engine takes.
    private func defaultReadout(_ value: Float) -> String {
        value == 0 ? "0" : String(format: "%+.0f", value * 100)
    }

    /// For a control centred mid-travel, where a signed readout would print
    /// "+50" for a slider that is doing nothing. 0…100, unsigned.
    private func unsignedReadout(_ value: Float) -> String {
        String(format: "%.0f", value * 100)
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
        // A section holding a property that travels is never neutral, whatever
        // the moment under the playhead reads.
        guard keyframedFields.isDisjoint(with: Self.fields(of: section)) else { return false }
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
            return adjustments.texture == 0 && adjustments.clarity == 0
                && adjustments.vignetteIntensity == 0
        case .detail:
            // The sub-sliders count too: the dot means "this section holds a
            // value", and a moved Masking is a value even while the Sharpen
            // it qualifies is parked at 0.
            return adjustments.sharpen == 0 && adjustments.noiseReduction == 0
                && adjustments.colorNoiseReduction == 0
                && adjustments.colorNoise == 0
                && adjustments.sharpenMasking == 0
                && adjustments.noiseDetail == PhotoAdjustments.neutralNoiseDetail
        }
    }

    /// Which controls live in which section — the one list both the header dot
    /// and the header's Reset work from.
    private static func fields(of section: PanelSection) -> Set<PhotoAdjustmentField> {
        switch section {
        case .whiteBalance: return [.temperature, .tint]
        case .light: return [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]
        case .color: return [.vibrance, .saturation]
        case .effects: return [.texture, .clarity, .vignetteIntensity]
        case .detail:
            return [.sharpen, .sharpenMasking, .noiseReduction, .noiseDetail,
                    .colorNoiseReduction, .colorNoise]
        }
    }

    private func reset(_ section: PanelSection) {
        if let onResetField {
            for field in Self.fields(of: section) { onResetField(field) }
            return
        }
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
            adjustments.texture = 0
            adjustments.clarity = 0
            adjustments.vignetteIntensity = 0
        case .detail:
            adjustments.sharpen = 0
            adjustments.sharpenMasking = 0
            adjustments.noiseReduction = 0
            adjustments.noiseDetail = PhotoAdjustments.neutralNoiseDetail
            adjustments.colorNoiseReduction = 0
            adjustments.colorNoise = 0
        }
    }

    /// `LL_SECTIONS=all|wb|light|color|effects|detail` forces the stacked
    /// layout's open state for design screenshots.
    private func applySectionHook() {
        #if DEBUG
        guard let hook = ProcessInfo.processInfo.environment["LL_SECTIONS"] else { return }
        switch hook {
        case "all": openSections = Set(PanelSection.allCases)
        case "wb": openSections = [.whiteBalance]
        case "light": openSections = [.light]
        case "color": openSections = [.color]
        case "effects": openSections = [.effects]
        case "detail": openSections = [.detail]
        default: break
        }
        #endif
    }
}

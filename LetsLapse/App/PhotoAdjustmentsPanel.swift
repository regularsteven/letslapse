import SwiftUI
import LetsLapseKit

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
    /// quick-picks — the frame under the playhead's own reading, from the raw
    /// converter. D65 when the file declares nothing.
    var asShotKelvin: Double = 6500
    /// The as-shot tint that goes with it, on the converter's ±150 axis.
    var asShotTint: Double = 0
    /// What the shoot's white balance is anchored to. `.asShot` — the default
    /// — leaves the Temp and Tint sliders measuring from each frame's own
    /// reading, which is why they cannot close a camera's mid-run white
    /// balance step; anything else pins the anchor and makes them absolute.
    var whiteBalanceSource: WhiteBalanceSource = .asShot
    /// Told when the white-balance anchor is changed from the menu. Unset in
    /// the surfaces that have no project to pin it on (a preset preview), where
    /// the anchor entries are hidden rather than inert.
    var onSetWhiteBalanceSource: ((WhiteBalanceSource) -> Void)?
    /// Where the playhead is, 0…1 — what "Match this frame" matches.
    var playheadPosition: Double = 0
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
        case rotation = "Rotation"
        var id: String { rawValue }
    }

    @State private var openSections: Set<PanelSection> = [.light]

    private var sections: [PanelSection] { PanelSection.allCases }

    var body: some View {
        Group {
            if alwaysExpanded {
                VStack(spacing: 14) {
                    ForEach(sections) { section in
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
                    ForEach(sections) { section in
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
            slider("Tint", field: .tint, readout: tintReadout)
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
        case .rotation:
            // The one control that is not a colour: the shared
            // `RotationSlider`, in its stacked shape, so a text layer's Angle
            // row and this one are the same instrument. It writes through
            // the same binding as every colour, so the timeline keyframes and
            // eases it exactly like them.
            RotationSlider(
                label: "Angle",
                degrees: Binding(
                    get: { Double(adjustments.rotationDegrees) },
                    set: { adjustments.rotationDegrees = Float($0) }),
                style: .stacked, accent: accent,
                onEditing: { editing in onFieldEditing?(.rotation, editing) },
                isKeyframed: keyframedFields.contains(.rotation),
                onReset: onResetField.map { reset in { reset(.rotation) } })
            Text("Levels the picture and crops in so no corner shows black. Baked into blended and guided clips; set it at more than one moment and it eases between them.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The white-balance anchor, and the named illuminants that pin it.
    ///
    /// Everything below the divider *pins the anchor* — it says what the light
    /// was, for the whole shoot, instead of nudging each frame away from what
    /// its own camera decided. That distinction is the reason the menu exists
    /// in this shape: over a sequence, a nudge cannot close a step the camera
    /// itself made, because both sides of the step get nudged equally.
    ///
    /// The named picks used to be slider-setters against the opening frame's
    /// as-shot; they now pin, which is what they always meant. "Custom" is the
    /// state where the sliders have been moved off whatever the anchor says.
    private var whiteBalanceMenu: some View {
        HStack {
            Text("White Bal.")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
            Spacer()
            Menu(currentQuickPickName) {
                Button("As Shot") { setSource(.asShot) }
                if onSetWhiteBalanceSource != nil {
                    Divider()
                    Button("Match This Frame") {
                        setSource(.fixed(kelvin: Float(asShotKelvin), tint: Float(asShotTint)))
                    }
                    Button("Smooth Auto WB") {
                        setSource(.smoothed(anchorPosition: playheadPosition))
                    }
                    Divider()
                    ForEach(Self.namedIlluminants, id: \.0) { name, kelvin in
                        Button(name) { setSource(.fixed(kelvin: Float(kelvin), tint: 0)) }
                    }
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .tint(accent)
        }
    }

    static let namedIlluminants: [(String, Double)] = [
        ("Sunny", 5500), ("Cloudy", 6500), ("Fluorescent", 4000), ("Tungsten", 3200),
    ]

    /// The illuminant the Temp and Tint sliders are measured from: the pinned
    /// one when the shoot has pinned one, and the frame under the playhead's
    /// own reading otherwise.
    private var anchorKelvin: Double {
        if case .fixed(let kelvin, _) = whiteBalanceSource { return Double(kelvin) }
        return asShotKelvin
    }

    private var anchorTint: Double {
        if case .fixed(_, let tint) = whiteBalanceSource { return Double(tint) }
        return asShotTint
    }

    private var anchorMired: Double { 1_000_000 / min(max(anchorKelvin, 1667), 25000) }

    private func setSource(_ source: WhiteBalanceSource) {
        // Pinning replaces the anchor, so an offset the sliders were carrying
        // was measured from somewhere else. With one look over the whole clip,
        // zeroing is the honest reset — the picked white IS the answer, not a
        // starting point to be nudged from.
        //
        // With KEYFRAMES it is not: those offsets are a hand-authored curve,
        // the binding writes only into the moment under the playhead, and
        // zeroing there would put a notch in the curve rather than clear it.
        // They are also the thing pinning an anchor is *for* — a white-balance
        // curve measured from a fixed white is what "keyframe to keyframe"
        // means — so the curve is left standing and rides the new anchor.
        if !hasKeyframes {
            adjustments.temperature = 0
            adjustments.tint = 0
        }
        onSetWhiteBalanceSource?(source)
    }

    private var currentQuickPickName: String {
        let moved = adjustments.temperature != 0 || adjustments.tint != 0
        switch whiteBalanceSource {
        case .asShot:
            return moved ? "Custom" : "As Shot"
        case .smoothed:
            return moved ? "Custom" : "Smoothed"
        case .fixed(let kelvin, let tint):
            guard !moved else { return "Custom" }
            if tint == 0, let named = Self.namedIlluminants.first(
                where: { abs($0.1 - Double(kelvin)) < 1 }) {
                return named.0
            }
            return "\(Int(kelvin.rounded())) K"
        }
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

    /// The absolute white the Temp slider currently declares.
    ///
    /// It reads as a Kelvin because that is what it is: the anchor moved by
    /// the slider's mired offset. The number is the one the renderer uses —
    /// both are anchored on `CIRAWFilter`'s reading now, where the readout
    /// used to solve its own from DNG tags that a camera-original raw does not
    /// carry, and answer 6500 K for every frame of a Sony shoot.
    ///
    /// Note it is Apple's converter's Kelvin, not Adobe's: the same file reads
    /// a little differently in Lightroom because the two use different camera
    /// profiles. What it guarantees is internal consistency — the same number
    /// on two frames is the same white.
    private func kelvinReadout(_ value: Float) -> String {
        guard value != 0 || !whiteBalanceSource.isAsShot else { return "As Shot" }
        let declaredMired = min(max(anchorMired - Double(value), 40), 600)
        return "\(Int((1_000_000 / declaredMired).rounded())) K"
    }

    /// The absolute tint, on the converter's own ±150 green–magenta axis — the
    /// axis Adobe's Tint slider also uses, so the two are comparable. The
    /// slider's own travel is ±1 recipe unit, which is ∓50 here; the constant
    /// and its sign are `LinearFrameDecoder.cirawTintPerRecipeUnit`.
    private func tintReadout(_ value: Float) -> String {
        let declared = min(max(anchorTint + Double(value * LinearFrameDecoder.cirawTintPerRecipeUnit),
                               -150), 150)
        // Always a number, never "As Shot": unlike Temp, whose zero genuinely
        // means "whatever the file said", a tint of zero still has an absolute
        // value worth reading — and "Temp 5635 K · Tint As Shot" reads as if
        // the two were measured differently, which they are not.
        let rounded = declared.rounded()
        return rounded == 0 ? "0" : String(format: "%+.0f", rounded)
    }

    // MARK: - Section state

    private func isNeutral(_ section: PanelSection) -> Bool {
        // A section holding a property that travels is never neutral, whatever
        // the moment under the playhead reads.
        guard keyframedFields.isDisjoint(with: Self.fields(of: section)) else { return false }
        switch section {
        case .whiteBalance:
            // A pinned anchor is a value the section holds even with both
            // sliders at zero — it is the setting that moved the pixels.
            return adjustments.temperature == 0 && adjustments.tint == 0
                && whiteBalanceSource.isAsShot
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
        case .rotation:
            return !adjustments.hasRotation
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
        case .rotation:
            return [.rotation]
        }
    }

    private func reset(_ section: PanelSection) {
        // Resetting White Balance unpins the anchor as well as zeroing the
        // sliders: "Reset" on that section has to mean "back to what the camera
        // said", and leaving the pin standing would reset to a different white
        // than the one the file was shot at.
        if section == .whiteBalance { onSetWhiteBalanceSource?(.asShot) }
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
        case .rotation:
            adjustments.rotationDegrees = 0
        }
    }

    /// `LL_SECTIONS=all|wb|light|color|effects|detail|rotation` forces the
    /// stacked layout's open state for design screenshots.
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
        case "rotation": openSections = [.rotation]
        default: break
        }
        #endif
    }
}

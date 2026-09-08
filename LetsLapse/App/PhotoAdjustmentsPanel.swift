import SwiftUI
import LetsLapseKit

/// The manual grade's controls — Lightroom-basic-panel parity, grouped the way
/// Lightroom groups them: White Balance, Light, Color, Color Mixer, Effects,
/// Detail, Rotation.
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
    /// The white the frame under the playhead renders at while nothing owns
    /// one — the smoothed track's value, or the frame's own as-shot from the
    /// raw converter. It is where the Temp and Tint sliders rest until they
    /// are moved, and what "Match This Frame" writes. D65 / 0 for a movie or
    /// a JPEG, which carry no reading of their own.
    var frameWhiteKelvin: Double = 6500
    var frameWhiteTint: Double = 0
    /// Whether the shoot is smoothing its camera's auto white balance under
    /// the grade. Only `.asShot` and `.smoothed` are meaningful here: an owned
    /// white lives in the keyframes, not in a source.
    var whiteBalanceSource: WhiteBalanceSource = .asShot
    /// Told when smoothing is switched on or off from the menu. Unset where
    /// there is no shoot to smooth (a movie, a preset preview), and the entry
    /// is hidden rather than inert.
    var onSetWhiteBalanceSource: ((WhiteBalanceSource) -> Void)?
    /// Where the playhead is, 0…1 — the frame a smoothed curve is levelled to.
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
        /// The HSL panel — eight hue bands, each with a hue turn, a
        /// saturation change and a luminance change. One axis shows at a
        /// time, picked by a segmented control, so the section is eight rows
        /// rather than twenty-four; the header dot and Reset cover all three.
        case mixer = "Color Mixer"
        case effects = "Effects"
        case detail = "Detail"
        case rotation = "Rotation"
        var id: String { rawValue }
    }

    /// The three things the Color Mixer can move about a band.
    enum MixerAxis: String, CaseIterable, Identifiable {
        case hue = "Hue"
        case saturation = "Saturation"
        case luminance = "Luminance"
        var id: String { rawValue }

        func value(of band: HSLAdjustments.Band, in panel: HSLAdjustments) -> Float {
            switch self {
            case .hue: return panel[hue: band]
            case .saturation: return panel[saturation: band]
            case .luminance: return panel[luminance: band]
            }
        }

        func set(_ value: Float, of band: HSLAdjustments.Band, in panel: inout HSLAdjustments) {
            switch self {
            case .hue: panel[hue: band] = value
            case .saturation: panel[saturation: band] = value
            case .luminance: panel[luminance: band] = value
            }
        }
    }

    @State private var openSections: Set<PanelSection> = [.light]
    /// Saturation first: on the twenty-file Lightroom corpus that drove this
    /// panel, saturation sliders outnumber hue sliders two to one.
    @State private var mixerAxis: MixerAxis = .saturation

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
                        // The owner's rail scrolls to a section by this id
                        // (`LL_SECTIONS` on the wide layout).
                        .id(section)
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
            }
        }
        .onAppear(perform: applySectionHook)
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
            whiteSlider
            whiteTintSlider
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
        case .mixer:
            mixerAxisPicker
            ForEach(HSLAdjustments.Band.allCases, id: \.self) { band in
                mixerRow(band)
            }
        case .effects:
            slider("Texture", field: .texture)
            slider("Clarity", field: .clarity)
            slider("Dehaze", field: .dehaze)
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

    // MARK: - White balance

    /// The white-balance menu. Everything in it writes the *white itself* —
    /// into the moment under the playhead, exactly as dragging the sliders
    /// would — because that is the only model in which two keyframes mean
    /// "from this white to that one" whatever the camera did in between. The
    /// one project-level entry is smoothing, which is what a frame renders at
    /// until a keyframe owns its white.
    private var whiteBalanceMenu: some View {
        HStack {
            Text("White Bal.")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
            Spacer()
            Menu(currentWhiteName) {
                Button("As Shot") { releaseWhite() }
                Button("Match This Frame") { ownWhite(kelvin: frameWhiteKelvin, tint: frameWhiteTint) }
                if onSetWhiteBalanceSource != nil {
                    Button("Smooth Auto WB") {
                        onSetWhiteBalanceSource?(.smoothed(anchorPosition: playheadPosition))
                    }
                }
                Divider()
                ForEach(Self.namedIlluminants, id: \.0) { name, kelvin in
                    Button(name) { ownWhite(kelvin: kelvin, tint: 0) }
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .tint(accent)
        }
    }

    static let namedIlluminants: [(String, Double)] = [
        ("Sunny", 5500), ("Cloudy", 6500), ("Fluorescent", 4000), ("Tungsten", 3200),
    ]

    private var frameWhiteMired: Float {
        Float(1_000_000 / min(max(frameWhiteKelvin, 1667), 25000))
    }

    /// Owns the white at this moment. Goes through the same binding a slider
    /// drag does, so the owner's timeline logic — keyframe write, seeding of
    /// the other moments — is the same logic.
    private func ownWhite(kelvin: Double, tint: Double) {
        var values = adjustments
        values.whiteMired = Float(1_000_000 / min(max(kelvin, 1667), 25000))
        values.whiteTint = Float(min(max(tint, -150), 150))
        adjustments = values
    }

    /// Back to the camera's own white here, and smoothing off. With a
    /// timeline in play the owner decides what releasing a property at one
    /// moment means (its neighbours' blend, or nothing at all).
    private func releaseWhite() {
        onSetWhiteBalanceSource?(.asShot)
        if let onResetField {
            onResetField(.whiteMired)
            onResetField(.whiteTint)
        } else {
            adjustments.whiteMired = 0
            adjustments.whiteTint = 0
        }
    }

    /// The menu's closed label: the owned white by name or by Kelvin, or what
    /// the frame is taking instead.
    private var currentWhiteName: String {
        guard let white = adjustments.ownedWhite else {
            if case .smoothed = whiteBalanceSource { return "Smoothed" }
            return "As Shot"
        }
        if white.tint == 0, let named = Self.namedIlluminants.first(
            where: { abs($0.1 - Double(white.kelvin)) < 1 }) {
            return named.0
        }
        return "\(Int(white.kelvin.rounded())) K"
    }

    /// Temp: the white itself, read out in Kelvin. The slider travels in
    /// mired so equal distances look equal, and is presented negated so the
    /// warm end is on the right, where every editor puts it. While nothing
    /// owns the white the knob rests on the frame's own; the first move owns
    /// it, carrying the frame's tint along so Tint does not jump to zero.
    private var whiteSlider: some View {
        let binding = Binding<Float>(
            get: { -(adjustments.ownsWhite ? adjustments.whiteMired : frameWhiteMired) },
            set: { presented in
                var values = adjustments
                if !values.ownsWhite { values.whiteTint = Float(frameWhiteTint) }
                values.whiteMired = min(max(-presented, PhotoAdjustments.whiteMiredRange.lowerBound),
                                        PhotoAdjustments.whiteMiredRange.upperBound)
                adjustments = values
            })
        return sliderRow(
            "Temp", field: .whiteMired, value: binding,
            range: -PhotoAdjustments.whiteMiredRange.upperBound ... -PhotoAdjustments.whiteMiredRange.lowerBound,
            isNeutral: !adjustments.ownsWhite,
            readout: { presented in "\(Int((1_000_000 / Double(-presented)).rounded())) K" },
            onReset: releaseWhiteFields)
    }

    /// Tint, on the converter's ±150 axis. Moving it owns the white too — a
    /// tint is a property of some white, never of none.
    private var whiteTintSlider: some View {
        let binding = Binding<Float>(
            get: { adjustments.ownsWhite ? adjustments.whiteTint : Float(frameWhiteTint) },
            set: { tint in
                var values = adjustments
                if !values.ownsWhite { values.whiteMired = frameWhiteMired }
                values.whiteTint = min(max(tint, -150), 150)
                adjustments = values
            })
        return sliderRow(
            "Tint", field: .whiteTint, value: binding,
            range: PhotoAdjustments.whiteTintRange,
            isNeutral: !adjustments.ownsWhite,
            readout: { $0.rounded() == 0 ? "0" : String(format: "%+.0f", $0.rounded()) },
            onReset: releaseWhiteFields)
    }

    /// A double-tap on either label releases both halves — they are one white.
    private func releaseWhiteFields() {
        if let onResetField {
            onResetField(.whiteMired)
            onResetField(.whiteTint)
        } else {
            adjustments.whiteMired = 0
            adjustments.whiteTint = 0
        }
    }

    // MARK: - Color Mixer

    private var mixerAxisPicker: some View {
        Picker("Axis", selection: $mixerAxis) {
            ForEach(MixerAxis.allCases) { axis in
                Text(axis.rawValue).tag(axis)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Color Mixer axis")
    }

    /// The panel as stored, or neutral while the grade holds none.
    private var mixerPanel: HSLAdjustments { adjustments.hsl ?? .neutral }

    /// One band on the current axis. Writes go through the same binding a
    /// slider does, so the owner's timeline logic — which moment the value
    /// belongs to — is the same logic; a panel that ends up neutral is stored
    /// as no panel at all.
    private func mixerBinding(_ band: HSLAdjustments.Band) -> Binding<Float> {
        Binding(
            get: { mixerAxis.value(of: band, in: mixerPanel) },
            set: { value in
                var values = adjustments
                var panel = values.hsl ?? .neutral
                mixerAxis.set(min(max(value, -1), 1), of: band, in: &panel)
                values.hsl = panel.isNeutral ? nil : panel
                adjustments = values
            })
    }

    private func mixerRow(_ band: HSLAdjustments.Band) -> some View {
        let value = mixerBinding(band)
        let isNeutral = value.wrappedValue == 0
        // The band's other two axes count too: a swatch reads "this colour
        // is being moved", whichever slider moved it.
        let bandMoved = MixerAxis.allCases.contains { $0.value(of: band, in: mixerPanel) != 0 }
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Self.swatch(for: band))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .accessibilityHidden(true)
                Text(band.lightroomName)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                if bandMoved && isNeutral {
                    // Moved on another axis: the smallest mark that says so.
                    Circle().fill(accent).frame(width: 4, height: 4)
                        .accessibilityHidden(true)
                }
                Spacer()
                Text(defaultReadout(value.wrappedValue))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isNeutral ? Color.secondary : Color.primary)
            }
            .contentShape(Rectangle())
            // Double-tap resets this band on this axis only; the header's
            // Reset clears the whole panel.
            .onTapGesture(count: 2) { value.wrappedValue = 0 }
            Slider(value: value, in: -1...1)
                .tint(accent)
                .accessibilityLabel("\(band.lightroomName) \(mixerAxis.rawValue.lowercased())")
        }
    }

    /// The band's colour, for its swatch: the panel's own hue centre at a
    /// saturation and brightness that read on a light card and a dark one.
    static func swatch(for band: HSLAdjustments.Band) -> Color {
        Color(hue: Double(band.centreDegrees) / 360, saturation: 0.82, brightness: 0.95)
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
        let neutral = field.neutralValue
        return sliderRow(
            label, field: field, value: value, range: field.range,
            isNeutral: value.wrappedValue == neutral, indented: indented,
            readout: readout ?? defaultReadout,
            onReset: {
                if let onResetField {
                    onResetField(field)
                } else {
                    value.wrappedValue = neutral
                }
            })
    }

    /// The row every control is built from: label, keyframe diamond, readout,
    /// slider. Takes the binding and range explicitly so a control whose
    /// presented value is not its stored one — the white, stored in mired and
    /// shown in Kelvin, resting on the frame's own value until owned — draws
    /// exactly like the rest.
    private func sliderRow(
        _ label: String,
        field: PhotoAdjustmentField,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        isNeutral: Bool,
        indented: Bool = false,
        readout: @escaping (Float) -> String,
        onReset: @escaping () -> Void
    ) -> some View {
        let isKeyframed = keyframedFields.contains(field)
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: indented ? 12.5 : 13.5))
                    .foregroundStyle(.secondary)
                if isKeyframed { keyframeDiamond }
                Spacer()
                Text(readout(value.wrappedValue))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(readoutStyle(isNeutral: isNeutral, isKeyframed: isKeyframed))
            }
            .contentShape(Rectangle())
            // Double-tap (double-click on the Mac) a label to reset just that
            // slider — the idiom every editor teaches. With a timeline in play
            // it is the owner's business: the value here belongs to a moment,
            // and taking a property out of that moment can retire it entirely.
            .onTapGesture(count: 2, perform: onReset)
            Slider(value: value, in: range) { editing in
                onFieldEditing?(field, editing)
            }
                .tint(accent)
                .accessibilityLabel(isKeyframed ? "\(label), keyframed" : label)
        }
        .padding(.leading, indented ? 14 : 0)
    }

    private func readoutStyle(isNeutral: Bool, isKeyframed: Bool) -> Color {
        // Accent whenever the property travels — the readout is then a value at
        // *this moment*, not a value for the clip, and that is worth saying
        // even when the number under the playhead happens to be neutral.
        if isKeyframed { return accent }
        return isNeutral ? Color.secondary : Color.primary
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

    // MARK: - Section state

    private func isNeutral(_ section: PanelSection) -> Bool {
        // A section holding a property that travels is never neutral, whatever
        // the moment under the playhead reads.
        guard keyframedFields.isDisjoint(with: Self.fields(of: section)) else { return false }
        switch section {
        case .whiteBalance:
            // Smoothing counts as a value the section holds: it moves the
            // pixels even while nothing owns the white.
            return !adjustments.ownsWhite && whiteBalanceSource.isAsShot
        case .light:
            return adjustments.exposure == 0 && adjustments.contrast == 0
                && adjustments.highlights == 0 && adjustments.shadows == 0
                && adjustments.whites == 0 && adjustments.blacks == 0
        case .color:
            return adjustments.vibrance == 0 && adjustments.saturation == 0
        case .mixer:
            return adjustments.hsl?.isNeutral ?? true
        case .effects:
            return adjustments.texture == 0 && adjustments.clarity == 0
                && adjustments.dehaze == 0 && adjustments.vignetteIntensity == 0
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
        case .whiteBalance: return [.whiteMired, .whiteTint]
        case .light: return [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]
        case .color: return [.vibrance, .saturation]
        // The mixer's twenty-four values are not `PhotoAdjustmentField`s: the
        // timeline carries the panel whole (held from the earlier keyframe,
        // never blended), so no diamond marks it and its reset is its own.
        case .mixer: return []
        case .effects: return [.texture, .clarity, .dehaze, .vignetteIntensity]
        case .detail:
            return [.sharpen, .sharpenMasking, .noiseReduction, .noiseDetail,
                    .colorNoiseReduction, .colorNoise]
        case .rotation:
            return [.rotation]
        }
    }

    private func reset(_ section: PanelSection) {
        // Resetting White Balance switches smoothing off as well as releasing
        // the white: "Reset" there has to mean "back to what the camera said".
        if section == .whiteBalance { onSetWhiteBalanceSource?(.asShot) }
        if section == .mixer {
            // Not a field, so not a timeline reset: the panel is taken out
            // of the moment under the playhead through the binding, which is
            // where a slider drag would have put it.
            var values = adjustments
            values.hsl = nil
            adjustments = values
            return
        }
        if let onResetField {
            for field in Self.fields(of: section) { onResetField(field) }
            return
        }
        switch section {
        case .whiteBalance:
            adjustments.whiteMired = 0
            adjustments.whiteTint = 0
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
        case .mixer:
            adjustments.hsl = nil
        case .effects:
            adjustments.texture = 0
            adjustments.clarity = 0
            adjustments.dehaze = 0
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

    /// `LL_SECTIONS=all|wb|light|color|mixer|effects|detail|rotation` forces
    /// the stacked layout's open state for design screenshots. `mixer` may
    /// carry an axis — `mixer:hue`, `mixer:luminance` — since the section
    /// shows one at a time; the axis applies to the expanded (Mac) layout
    /// too, which has no cards to open.
    private func applySectionHook() {
        #if DEBUG
        guard let hook = ProcessInfo.processInfo.environment["LL_SECTIONS"] else { return }
        if hook.hasPrefix("mixer") {
            if let axis = hook.split(separator: ":").dropFirst().first,
               let picked = MixerAxis.allCases.first(where: { $0.rawValue.lowercased() == axis.lowercased() }) {
                mixerAxis = picked
            }
            guard !alwaysExpanded else { return }
            openSections = [.mixer]
            return
        }
        guard !alwaysExpanded else { return }
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

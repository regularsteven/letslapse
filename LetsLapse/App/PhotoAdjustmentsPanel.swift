import SwiftUI
import LetsLapseKit

// Mirrors the group panel of boards 2a (iPhone bottom sheet), 5a (iPad
// floating card), 3b / 6c (Mac rail card) and 6e (pads off) — spec §1–§3 and
// §8–§10. `board-logic.js` `floatingF` is the behavioural source: one group at
// a time, a chip per tool, a pad (or two sliders) per chip.

/// Which dressing the panel wears. The owner picks by platform and width;
/// the panel's content is the same under all three.
enum EditorPanelLayout {
    /// 2a: the iPhone's bottom sheet, edge to edge over the picture's foot.
    /// The owner places it at the bottom of the safe area; the card's
    /// material runs under the home indicator by itself.
    case phone
    /// 5a: the iPad's 400 pt floating card, draggable by its header. The
    /// Presets group fills whatever height the owner gives it.
    case floating
    /// 3b: the Mac rail's card — and, drawn dark, the rail on a landscape
    /// iPhone.
    case rail
}

/// What the Presets group needs from its owner: the frame to render tiles on,
/// the state pill, the saved presets, the render cache, and the actions a
/// tile tap can lead to. Nil on the panel means the owner has no presets to
/// show at all (a masked grade), and the group draws nothing but its header.
struct EditorPresetsContext {
    /// The frame under the playhead — `.still(url)` / `.movie(url)` — or nil
    /// when the owner has none to render on; the tiles then show placeholders.
    var frame: PresetPreviewFrame?
    var presetState: PresetState
    /// The built-in the project's grade stands on — `PhotoGrade.preset`.
    /// While the state is Edited the pill says so and the base's tile keeps
    /// its ring, so "Natural (ringed) · Edited" reads as the board draws it;
    /// a named state rings the named tile instead, and Original is never
    /// ringed while Edited (an edited Original is just edits).
    var basePreset: PhotoPreset
    var customPresets: [CustomPreset]
    /// The owner owns one `@StateObject` and hands it in, so renders survive
    /// the phone panel being torn down between opens.
    var cache: PresetThumbnailCache
    /// A tile tap — the owner's `request(_:)`, which may confirm first.
    var onSelect: (PresetApplyRequest.Target) -> Void
    /// "Delete preset" on a saved preset's tile; nil hides the entry.
    var onDelete: ((CustomPreset) -> Void)?
    var onSaveAsPreset: () -> Void
    /// The owner's inline "Save these edits as a preset?" card, when it wants
    /// it shown here rather than in its own rail.
    var saveOffer: AnyView?
    /// The owner's Lightroom import card, when a sidecar exists.
    var lightroomCard: AnyView?
}

/// The manual grade's controls — one `EditorGroup` at a time.
///
/// Shared by both editors — `PhotoViewerView` (photo and interval captures)
/// and `VideoEditorView` — so the surfaces can't drift apart. It owns no
/// render state: the binding's owner decides how often to re-render and when
/// to write the values back to the project. It owns no snapshot either: the
/// owner holds which group is open and the ✓/✕ snapshot, and the panel only
/// reports `onCommit` / `onCancel`. What it does hold is the two things that
/// are nobody else's business — which mixer band is selected, and whether
/// the white was last set by Auto — and the chip selection is the owner's,
/// through `toolSelection`, so it survives the phone panel being torn down
/// between opens.
///
/// Every control writes through the one `adjustments` binding, and a pad
/// writes BOTH of its fields in one assignment: with a timeline in play each
/// assignment is one keyframe write, and two writes per tick would be two.
struct PhotoAdjustmentsPanel: View {
    @Binding var adjustments: PhotoAdjustments
    var group: EditorGroup
    var layout: EditorPanelLayout
    /// `.dark` on the iOS editors, `.light` on the Mac — colours, knob sizes,
    /// chip look. The header's shape follows it too: the dark editors get
    /// the ✕ / ✓ circles, the Mac card gets Revert / Done.
    var style: XYPadStyle
    /// Which tool chip is up in each group — owner-held so it survives the
    /// phone panel being torn down between opens (spec §3: "persists per
    /// group within the session").
    @Binding var toolSelection: [EditorGroup: EditorTool]
    /// The white the frame under the playhead renders at while nothing owns
    /// one — the smoothed track's value, or the frame's own as-shot from the
    /// raw converter. It is where the Temp and Tint controls rest until they
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
    /// their readout (and on their tool's chip) and an accent readout, per
    /// design treatment `1e-A`. Empty for a still, and for every clip graded
    /// with one look end to end.
    var keyframedFields: Set<PhotoAdjustmentField> = []
    /// True when the grade holds keyframes at all, so "Reset all adjustments"
    /// stays live even where the moment on screen happens to read neutral.
    var hasKeyframes: Bool = false
    /// Where a reset goes when the owner has a timeline to consider — zeroing
    /// the binding would write the zero into the moment under the playhead
    /// rather than taking the property back out of it. Unset (a still, or a
    /// clip with no keyframes) keeps the plain behaviour.
    var onResetField: ((PhotoAdjustmentField) -> Void)?
    /// Same, for "Reset all adjustments": with keyframes there is a timeline
    /// to clear as well as values to neutralise.
    var onResetAll: (() -> Void)?
    /// Told when a control is grabbed and when it is let go — for both of a
    /// pad's fields at once. The photo editor uses it to float a 1:1 detail
    /// loupe over the picture while one of the pixel-level controls —
    /// Sharpen, Noise — is moving, because those are exactly the controls
    /// whose effect a fit-to-screen preview cannot show; both editors persist
    /// on the release.
    var onFieldEditing: ((PhotoAdjustmentField, Bool) -> Void)?
    /// The Presets group's data and actions; nil where the owner has none
    /// (a masked grade).
    var presets: EditorPresetsContext?
    /// WB Auto (spec §8): the owner renders the frame under the playhead and
    /// estimates a white; the panel writes it like a menu pick. Nil hides the
    /// button — a movie has no raw white to declare.
    var autoWhite: (() async -> AutoWhiteBalance.Estimate?)?
    /// The levelled picture's width ÷ height, for `FrameCrop.fitted` when an
    /// aspect chip is tapped.
    var cropFrameAspect: Double = 4 / 3
    /// What an aspect chip does when the owner draws NO crop frame over its
    /// picture (the video editor's player, which shows the whole movie and
    /// cuts on export): the hint under the chips ends with this note instead
    /// of the drag / pinch instructions. Nil = a frame is there to drag.
    var cropNote: String?
    /// ✓ / Done — the owner closes and keeps.
    var onCommit: () -> Void = {}
    /// ✕ / Revert — the owner restores its snapshot and closes.
    var onCancel: () -> Void = {}
    /// Floating layout only: the header's drag — translation since the drag
    /// started, and `true` on the end — so the owner can move the card with
    /// the frozen-base idiom (`MediaResizeHandle`'s: base + translation, never
    /// accumulated deltas).
    var onHeaderDrag: ((CGSize, Bool) -> Void)?
    /// The mixer band to open on, when the owner has one to ask for —
    /// `LL_SECTIONS=color:mixer:<band>` staging a mirror on Blue. Read once,
    /// on appearance; the band is the panel's own state after that.
    var initialBand: HSLAdjustments.Band?

    /// Settings › Advanced › Layout › "Use Pads in Editor" (decision 4). Off,
    /// every pad renders as its two sliders, Y field first; chips and
    /// grouping are unchanged.
    @AppStorage(LayoutSettings.editorPadsKey) private var usesPads = true
    /// The mixer's selected band. Orange first: it is the band the boards
    /// open on, and the one a sky-and-skin shoot reaches for.
    @State private var band: HSLAdjustments.Band = .orange
    /// The white the last Auto wrote, so the menu reads "Auto" for exactly
    /// as long as the white under the playhead IS the estimate — a value to
    /// compare against rather than a flag to clear, because the white can
    /// change without the panel knowing: a scrub to another moment, a ✕
    /// restore, a preset, a keyframe deleted. Any of those and the name
    /// drops by itself.
    @State private var autoWhiteWritten: (mired: Float, tint: Float)?
    /// True while the owner's estimate is running, so a second tap cannot
    /// queue a second render.
    @State private var autoRunning = false

    // MARK: - Body

    var body: some View {
        Group {
            switch layout {
            case .phone: phoneContainer
            case .floating: floatingContainer
            case .rail: railContainer
            }
        }
        .onAppear { if let initialBand { band = initialBand } }
    }

    private var panelStack: some View {
        VStack(spacing: 10) {
            header
            content
        }
    }

    /// `rgba(28,28,30,.86)` over a blur — the sheet and the floating card.
    private var chromeFill: Color {
        Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.86)
    }

    /// 2a: padded 12 top / 16 sides / 0 bottom in a 22 pt top-cornered sheet
    /// that runs under the home indicator (the background ignores the bottom
    /// safe area; the content does not), shadow up.
    private var phoneContainer: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
        return panelStack
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(chromeFill)
                }
                // One composited layer casts one shadow; two translucent
                // fills would each cast their own.
                .compositingGroup()
                .shadow(color: .black.opacity(0.45), radius: 30, y: -8)
                .ignoresSafeArea(edges: .bottom)
            }
    }

    /// 5a: 400 wide, padded 8 top / 16 sides / 16 bottom in a 22 pt card.
    private var floatingContainer: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return panelStack
            .padding(.top, 8)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(width: 400)
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(chromeFill)
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.5), radius: 40, y: 12)
            }
    }

    /// 3b: a radius-12 card in the rail — white on the Mac; on the iOS rail
    /// `LL.cardBackground` is dark under the editor's forced dark scheme.
    private var railContainer: some View {
        panelStack
            .padding(12)
            .llCard(cornerRadius: 12)
    }

    // MARK: - Style

    /// The Mac's light card versus the dark editors — most metrics follow
    /// this rather than the layout, since the iOS rail is dark too.
    private var isLight: Bool { style == .light }

    /// Slider labels: white on the dark editors, `#6D6D72` on the Mac.
    private var labelInk: Color { isLight ? EditorPalette.secondaryOnLight : .white }

    /// Secondary captions — the "White Bal." label, the crop hint.
    private var secondaryInk: Color {
        isLight ? EditorPalette.secondaryOnLight : EditorPalette.secondaryOnDark
    }

    /// The fill behind the small pills — Auto, the illuminant menu.
    private var pillFill: Color { isLight ? EditorPalette.pillFillOnLight : Color.white.opacity(0.1) }

    private var padHeight: CGFloat { layout == .floating ? 180 : 170 }

    /// Accent whenever the property travels — the readout is then a value at
    /// *this moment*, not a value for the clip, and that is worth saying even
    /// when the number under the playhead happens to be neutral. Otherwise
    /// the board's rule: secondary at neutral, accent (dark) / black (Mac)
    /// once moved.
    private func readoutInk(isNeutral: Bool, isKeyframed: Bool) -> Color {
        if isKeyframed { return accent }
        if isNeutral { return secondaryInk }
        return isLight ? Color.primary : accent
    }

    /// `LL_PADS=off` forces the sliders for a screenshot without touching the
    /// real setting.
    private var padsEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LL_PADS"] == "off" { return false }
        #endif
        return usesPads
    }

    // MARK: - Header

    /// The floating card adds a grab bar above the title row, and the two
    /// together are the drag handle.
    @ViewBuilder private var header: some View {
        if layout == .floating {
            VStack(spacing: 6) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 36, height: 5)
                titleRow
            }
            .contentShape(Rectangle())
            .gesture(headerDrag)
        } else {
            titleRow
        }
    }

    private var headerDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { onHeaderDrag?($0.translation, false) }
            .onEnded { onHeaderDrag?($0.translation, true) }
    }

    @ViewBuilder private var titleRow: some View {
        if isLight {
            HStack(spacing: 6) {
                titleLabel
                Spacer(minLength: 0)
                // The Presets card's reset IS the Original tile in the grid
                // below, and at the Mac's 274 pt card the title, the state
                // pill, Reset, Revert and Done do not all fit on one line —
                // so that card keeps the pill and drops the button.
                if !groupIsNeutral, group != .presets {
                    Button("Reset") { reset(group) }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                        .buttonStyle(.plain)
                }
                macPill("Revert", fill: EditorPalette.pillFillOnLight, ink: .primary, horizontal: 10, action: onCancel)
                macPill("Done", fill: LL.accent, ink: .white, horizontal: 12, action: onCommit)
            }
        } else {
            HStack(spacing: 6) {
                titleLabel
                    // The ✕ reverts rather than resets, so the resets live
                    // under a long-press on the title (spec §3).
                    .contextMenu {
                        Button("Reset \(group.title)") { reset(group) }
                            .disabled(groupIsNeutral)
                        Button("Reset all adjustments") { resetAll() }
                            .disabled(!canResetAll)
                    }
                Spacer()
                circleButton(
                    "xmark", fill: Color.white.opacity(0.1), ink: .white, size: 12,
                    label: "Revert", action: onCancel)
                circleButton(
                    "checkmark", fill: accent, ink: .black, size: 13,
                    label: "Done", action: onCommit)
            }
        }
    }

    /// Title, the Presets state pill, and the 6 pt dot — drawn clear rather
    /// than removed when the group is neutral so the row never reflows.
    private var titleLabel: some View {
        HStack(spacing: 6) {
            Text(group.title)
                .font(.system(size: isLight ? 13.5 : 15, weight: .semibold))
                .foregroundStyle(isLight ? EditorPalette.secondaryOnLight : .white)
                .lineLimit(1)
                .fixedSize()
            if group == .presets, let presets {
                PresetStatePill(
                    state: presets.presetState, accent: accent,
                    onAccent: isLight ? .white : .black)
            }
            Circle()
                .fill(groupIsNeutral ? Color.clear : accent)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(groupIsNeutral ? "" : "adjusted")
    }

    private func circleButton(
        _ symbol: String, fill: Color, ink: Color, size: CGFloat, label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func macPill(
        _ title: String, fill: Color, ink: Color, horizontal: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink)
                .padding(.vertical, 4)
                .padding(.horizontal, horizontal)
                .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch group {
        case .presets: presetsContent
        case .crop: cropContent
        case .light, .color, .effects, .detail: toolsContent
        }
    }

    // MARK: - Presets

    /// The tiles show each preset ALONE on the frame under the playhead: a
    /// built-in at neutral adjustments, a saved preset as the whole grade it
    /// is (base look plus its own values). Not "this preset + my edits",
    /// which spec §9 first asked for: tapping a built-in REPLACES the edits
    /// (`apply(.builtIn)` writes neutral values), so a tile composed with
    /// them would promise a picture the tap cannot produce. The tile is the
    /// tap's honest preview (settled 2026-09-13). The geometry in hand is
    /// left out of the tiles as well — the picture is the look, not the
    /// crop — and stays on the project when a preset is applied.
    @ViewBuilder private var presetsContent: some View {
        if let presets {
            switch layout {
            case .phone:
                // Bleeds edge to edge under the sheet's 16 pt sides (the
                // board's `margin: 0 -16px`), the tiles inset back by 16.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        presetTiles(presets, tileStyle: .phone)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
                presetsFooter(presets)
            case .floating:
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                            spacing: 10
                        ) {
                            presetTiles(presets, tileStyle: .padGrid)
                        }
                        presetsFooter(presets)
                    }
                }
                .frame(maxHeight: .infinity)
            case .rail:
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    presetTiles(presets, tileStyle: .macGrid)
                }
                presetsFooter(presets)
            }
        }
    }

    @ViewBuilder private func presetTiles(
        _ presets: EditorPresetsContext, tileStyle: PresetTileStyle
    ) -> some View {
        ForEach(PhotoPreset.strip) { preset in
            EditorPresetThumbnail(
                name: preset.displayName,
                grade: PhotoGrade(preset: preset, adjustments: .neutral),
                frame: presets.frame,
                cache: presets.cache,
                isSelected: Self.isBuiltInRinged(preset, in: presets),
                accent: accent,
                style: tileStyle
            ) {
                presets.onSelect(.builtIn(preset))
            }
        }
        ForEach(presets.customPresets) { custom in
            EditorPresetThumbnail(
                name: custom.name,
                grade: PhotoGrade(preset: custom.basePreset, adjustments: custom.adjustments),
                frame: presets.frame,
                cache: presets.cache,
                isSelected: presets.presetState.isNamed(custom.id),
                accent: accent,
                style: tileStyle
            ) {
                presets.onSelect(.custom(custom))
            }
            .contextMenu {
                if let onDelete = presets.onDelete {
                    Button("Delete preset", role: .destructive) { onDelete(custom) }
                }
            }
        }
    }

    /// Which built-in tile carries the ring. Original's ring means "no
    /// preset" and follows `isOriginal` alone. Any other built-in is ringed
    /// while it is the named state, and also while the state is Edited and
    /// it is the base the edits sit on — the state pill already says Edited,
    /// so the ring is free to say which look was edited.
    private static func isBuiltInRinged(_ preset: PhotoPreset, in presets: EditorPresetsContext) -> Bool {
        if preset == .original { return presets.presetState.isOriginal }
        if presets.presetState.isNamed(preset.presetID) { return true }
        return presets.presetState.isEdited && presets.basePreset == preset
    }

    /// Under the tiles: the owner's Lightroom card, then ONE way to keep the
    /// edits in hand — the owner's inline offer when it is making one (the
    /// offer carries its own Save as Preset button), otherwise the plain
    /// row. This is the only place the offer appears.
    @ViewBuilder private func presetsFooter(_ presets: EditorPresetsContext) -> some View {
        if let card = presets.lightroomCard { card }
        if let offer = presets.saveOffer {
            offer
        } else {
            Button(action: presets.onSaveAsPreset) {
                Label("Save as Preset", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Tool groups

    private var selectedTool: EditorTool? { toolSelection[group] ?? group.tools.first }

    private var toolBinding: Binding<EditorTool?> {
        Binding(
            get: { selectedTool },
            set: { tool in
                if let tool { toolSelection[group] = tool }
            })
    }

    /// A chip carries the diamond when either of its fields travels.
    private var keyframedTools: Set<EditorTool> {
        Set(group.tools.filter { !$0.fields.isDisjoint(with: keyframedFields) })
    }

    @ViewBuilder private var toolsContent: some View {
        EditorToolChips(
            tools: group.tools, selection: toolBinding, keyframed: keyframedTools,
            style: style, accent: accent)
        if let tool = selectedTool {
            toolContent(tool)
        }
    }

    /// The rows under the chips, top to bottom: the WB row or the band row
    /// where the tool has one, the pad (or its two sliders, Y field first),
    /// the readouts, then the extra sliders — the mixer's band saturation,
    /// Noise's Detail.
    @ViewBuilder private func toolContent(_ tool: EditorTool) -> some View {
        if tool == .whiteBalance { whiteBalanceRow }
        if tool == .mixer { bandRow }
        if let spec = tool.pad, let axes = axes(for: tool) {
            // The mixer's placeholder background is replaced by the band's.
            let background: PadBackground = tool == .mixer
                ? .mixer(hueDegrees: Self.boardHueDegrees(for: band))
                : spec.background
            if padsEnabled {
                pad(y: axes.y, x: axes.x, words: spec.words, background: background)
            } else {
                sliderRow(axes.y) { resetAxis(axes.y) }
                sliderRow(axes.x) { resetAxis(axes.x) }
            }
        } else {
            // Dehaze: the one plain-slider tool, in both modes.
            slider("Dehaze", field: .dehaze)
        }
        if tool == .mixer {
            let saturation = mixerAxis("Saturation", .saturation)
            sliderRow(saturation) { resetAxis(saturation) }
        }
        ForEach(tool.extraSliders, id: \.self) { field in
            slider(Self.extraLabel(for: field), field: field, indented: true, readout: Self.unsignedReadout)
        }
    }

    private static func extraLabel(for field: PhotoAdjustmentField) -> String {
        switch field {
        case .noiseDetail: return "Detail"
        default: return field.rawValue
        }
    }

    // MARK: - Axes

    /// One axis of a pad, or one slider row in sliders mode — the same
    /// description serves both, so a control's presentation (the sign and
    /// scale it shows, which is not always what is stored) is spelled once.
    /// `set` and `reset` write into a copy the caller assigns, which is how a
    /// pad's two axes land in one write.
    private struct PadAxis {
        var label: String
        /// The field, for the keyframe diamond and `onFieldEditing`; nil for
        /// the mixer's band values, which are not fields.
        var field: PhotoAdjustmentField?
        /// The PRESENTED range and neutral — the control's, not the store's.
        var range: ClosedRange<Float>
        var neutral: Float
        var isNeutral: () -> Bool
        var readout: (Float) -> String
        /// The presented value now — read live, never captured, so a binding
        /// built from it is right on the tick after a write.
        var get: () -> Float
        var set: (inout PhotoAdjustments, Float) -> Void
        /// The plain reset — what to write when no timeline is in play.
        var reset: (inout PhotoAdjustments) -> Void
        /// What a timeline reset retires. Usually `[field]`; both halves for
        /// either white balance axis (they are one white); empty for the
        /// mixer, whose reset is never a timeline reset.
        var resetFields: [PhotoAdjustmentField]
        /// A gradient track in sliders mode — Temp and Tint; nil is the
        /// native slider.
        var track: [Color]? = nil
        /// A sub-slider that qualifies the one above it (Detail under Noise
        /// Reduction): steps in and drops a point of type size.
        var indented: Bool = false
    }

    /// The straightforward case: a field shown as stored.
    private func axis(
        _ label: String, _ field: PhotoAdjustmentField,
        readout: @escaping (Float) -> String = PhotoAdjustmentsPanel.defaultReadout,
        indented: Bool = false
    ) -> PadAxis {
        let path = field.keyPath
        let range = field.range
        let neutral = field.neutralValue
        return PadAxis(
            label: label, field: field, range: range, neutral: neutral,
            isNeutral: { adjustments[keyPath: path] == neutral },
            readout: readout,
            get: { adjustments[keyPath: path] },
            set: { values, presented in
                values[keyPath: path] = min(max(presented, range.lowerBound), range.upperBound)
            },
            reset: { $0[keyPath: path] = neutral },
            resetFields: [field],
            indented: indented)
    }

    /// The pad and slider pairs, Y then X, per spec §2. Nil for Dehaze.
    private func axes(for tool: EditorTool) -> (y: PadAxis, x: PadAxis)? {
        switch tool {
        case .expCon:
            return (axis("Exposure", .exposure, readout: Self.exposureReadout), axis("Contrast", .contrast))
        case .highWhites:
            return (axis("Highlights", .highlights), axis("Whites", .whites))
        case .shadBlacks:
            return (axis("Shadows", .shadows), axis("Blacks", .blacks))
        case .whiteBalance:
            return (tempAxis, tintAxis)
        case .vibSat:
            return (axis("Saturation", .saturation), axis("Vibrance", .vibrance))
        case .mixer:
            return (mixerAxis("Hue", .hue), mixerAxis("Luminance", .luminance))
        case .texClar:
            return (axis("Clarity", .clarity), axis("Texture", .texture))
        case .vignette:
            return (vignetteAxis, axis("Midpoint", .vignetteMidpoint, readout: Self.unsignedReadout))
        case .dehaze:
            return nil
        case .sharpen:
            return (axis("Sharpen", .sharpen, readout: Self.unsignedReadout),
                    axis("Masking", .sharpenMasking, readout: Self.unsignedReadout))
        case .noise:
            return (axis("Noise Reduction", .noiseReduction, readout: Self.unsignedReadout),
                    axis("Color Noise", .colorNoiseReduction, readout: Self.unsignedReadout))
        }
    }

    /// Vignette, Lightroom's way up: the store keeps positive = darken (what
    /// every project and preset already means), the control shows up / right
    /// = lighten = "+", so it presents the NEGATED value — exactly as Temp
    /// negates mired (decision 2).
    private var vignetteAxis: PadAxis {
        let range = PhotoAdjustments.vignetteRange
        return PadAxis(
            label: "Vignette", field: .vignetteIntensity,
            range: -range.upperBound ... -range.lowerBound, neutral: 0,
            isNeutral: { adjustments.vignetteIntensity == 0 },
            readout: Self.defaultReadout,
            get: { -adjustments.vignetteIntensity },
            set: { values, presented in
                values.vignetteIntensity = -min(max(presented, -range.upperBound), -range.lowerBound)
            },
            reset: { $0.vignetteIntensity = 0 },
            resetFields: [.vignetteIntensity])
    }

    // MARK: - Pads

    /// 0…1 along an axis, the lower bound at 0.
    private static func normalized(_ value: Float, in range: ClosedRange<Float>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    private static func denormalized(_ t: CGFloat, in range: ClosedRange<Float>) -> Float {
        range.lowerBound + Float(min(max(t, 0), 1)) * (range.upperBound - range.lowerBound)
    }

    private func isKeyframed(_ axis: PadAxis) -> Bool {
        axis.field.map { keyframedFields.contains($0) } ?? false
    }

    /// The pad and its readouts. One binding maps both axes to the pad's
    /// normalized square; its setter builds ONE copy with both fields set and
    /// assigns it once per tick.
    @ViewBuilder private func pad(
        y: PadAxis, x: PadAxis, words: PadWords, background: PadBackground
    ) -> some View {
        let value = Binding<CGPoint>(
            get: {
                CGPoint(
                    x: Self.normalized(x.get(), in: x.range),
                    y: Self.normalized(y.get(), in: y.range))
            },
            set: { point in
                var values = adjustments
                y.set(&values, Self.denormalized(point.y, in: y.range))
                x.set(&values, Self.denormalized(point.x, in: x.range))
                adjustments = values
            })
        let neutral = CGPoint(
            x: Self.normalized(x.neutral, in: x.range),
            y: Self.normalized(y.neutral, in: y.range))
        let fields = [y.field, x.field].compactMap { $0 }
        XYPad(
            value: value, neutral: neutral, words: words, background: background,
            style: style, height: padHeight, yName: y.label, xName: x.label,
            onEditing: { editing in
                for field in fields { onFieldEditing?(field, editing) }
            },
            onReset: { resetPad(y: y, x: x) })
        PadReadouts(
            yLabel: y.label, yValue: y.readout(y.get()), yKeyframed: isKeyframed(y),
            xLabel: x.label, xValue: x.readout(x.get()), xKeyframed: isKeyframed(x),
            accent: accent, style: style)
    }

    /// Double-tap on the pad: both fields, through the owner when it has a
    /// timeline to consider (a property comes back out of the moment), else
    /// both neutrals in one write.
    private func resetPad(y: PadAxis, x: PadAxis) {
        var fields = y.resetFields
        for field in x.resetFields where !fields.contains(field) { fields.append(field) }
        if let onResetField, !fields.isEmpty {
            for field in fields { onResetField(field) }
        } else {
            var values = adjustments
            y.reset(&values)
            x.reset(&values)
            adjustments = values
        }
    }

    /// Double-tap on a slider row's label: that axis alone — which for
    /// either white balance row is still both halves, they being one white.
    private func resetAxis(_ axis: PadAxis) {
        if let onResetField, !axis.resetFields.isEmpty {
            for field in axis.resetFields { onResetField(field) }
        } else {
            var values = adjustments
            axis.reset(&values)
            adjustments = values
        }
    }

    // MARK: - Sliders

    /// One control. `indented` marks a sub-slider — a control that qualifies
    /// the one above it rather than standing on its own (Detail under Noise
    /// Reduction), so it steps in and drops a point of type size instead of
    /// claiming a row of its own.
    private func slider(
        _ label: String,
        field: PhotoAdjustmentField,
        indented: Bool = false,
        readout: @escaping (Float) -> String = PhotoAdjustmentsPanel.defaultReadout
    ) -> some View {
        let axis = axis(label, field, readout: readout, indented: indented)
        return sliderRow(axis) { resetAxis(axis) }
    }

    private func binding(for axis: PadAxis) -> Binding<Float> {
        Binding(
            get: axis.get,
            set: { presented in
                var values = adjustments
                axis.set(&values, presented)
                adjustments = values
            })
    }

    /// The row every slider is built from: label, keyframe diamond, readout,
    /// then the track — the native slider, or the gradient one where the
    /// axis carries a track. Takes the axis whole so a control whose
    /// presented value is not its stored one — the white, stored in mired
    /// and shown in Kelvin, resting on the frame's own value until owned —
    /// draws exactly like the rest.
    private func sliderRow(_ axis: PadAxis, onReset: @escaping () -> Void) -> some View {
        let keyframed = isKeyframed(axis)
        let value = binding(for: axis)
        let current = axis.get()
        let accessibilityLabel = keyframed ? "\(axis.label), keyframed" : axis.label
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(axis.label)
                    .font(.system(size: axis.indented ? 12.5 : 13.5))
                    .foregroundStyle(labelInk)
                if keyframed { KeyframeDiamond() }
                Spacer()
                Text(axis.readout(current))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(readoutInk(isNeutral: axis.isNeutral(), isKeyframed: keyframed))
            }
            .contentShape(Rectangle())
            // Double-tap (double-click on the Mac) a label to reset just that
            // slider — the idiom every editor teaches. With a timeline in play
            // it is the owner's business: the value here belongs to a moment,
            // and taking a property out of that moment can retire it entirely.
            .onTapGesture(count: 2, perform: onReset)
            if let track = axis.track {
                GradientTrackSlider(
                    value: value, range: axis.range, colors: track, style: style,
                    onEditing: { editing in
                        if let field = axis.field { onFieldEditing?(field, editing) }
                    },
                    accessibilityLabel: accessibilityLabel,
                    accessibilityValue: axis.readout(current))
            } else {
                Slider(value: value, in: axis.range) { editing in
                    if let field = axis.field { onFieldEditing?(field, editing) }
                }
                .tint(accent)
                .accessibilityLabel(accessibilityLabel)
            }
        }
        .padding(.leading, axis.indented ? 14 : 0)
    }

    // MARK: - Readouts

    /// `String(format:)` prints a hyphen-minus for a negative number; the
    /// boards — and `RotationSlider.readout` — print a real minus sign,
    /// U+2212, which sits at the plus sign's height and width so "−12" and
    /// "+12" line up under a pad. Every readout the panel formats passes
    /// through here, so no formatter can drift back to the hyphen.
    static func minusSigned(_ formatted: String) -> String {
        formatted.replacingOccurrences(of: "-", with: "−")
    }

    /// Slider values read as −100…100, which is the vocabulary people know
    /// from every other editor, rather than the −1…1 the engine takes.
    static func defaultReadout(_ value: Float) -> String {
        // Rounded before the sign test, like the board's `S()`: a value a
        // hair off zero reads "0", not "+0".
        let rounded = (value * 100).rounded()
        return rounded == 0 ? "0" : minusSigned(String(format: "%+.0f", rounded))
    }

    /// For a control centred mid-travel or with no negative side, where a
    /// signed readout would print "+50" for a slider that is doing nothing.
    /// 0…100, unsigned.
    static func unsignedReadout(_ value: Float) -> String {
        minusSigned(String(format: "%.0f", value * 100))
    }

    static func exposureReadout(_ value: Float) -> String {
        abs(value) < 0.005 ? "0" : minusSigned(String(format: "%+.2f", value))
    }

    /// Tint's readout: the converter's ±150 axis as a whole number, signed.
    static func tintReadout(_ value: Float) -> String {
        let rounded = value.rounded()
        return rounded == 0 ? "0" : minusSigned(String(format: "%+.0f", rounded))
    }

    // MARK: - White balance

    /// The row above the WB pad: "White Bal.", Auto, and the illuminant menu.
    private var whiteBalanceRow: some View {
        HStack(spacing: 8) {
            Text("White Bal.")
                .font(.system(size: 13.5))
                .foregroundStyle(secondaryInk)
                .lineLimit(1)
            Spacer()
            if autoWhite != nil { autoButton }
            whiteBalanceMenu
        }
    }

    /// WB Auto (spec §8): the owner's grey-world estimate of the frame under
    /// the playhead, written like a menu pick — into the moment, through the
    /// same binding — so it keyframes identically.
    private var autoButton: some View {
        Button(action: runAutoWhite) {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                Text("Auto")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(accent)
            .padding(.vertical, isLight ? 3 : 4)
            .padding(.horizontal, isLight ? 9 : 10)
            .background(pillFill, in: RoundedRectangle(cornerRadius: isLight ? 6 : 13, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: isLight ? 6 : 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(autoRunning)
        .accessibilityLabel("Auto white balance")
    }

    private func runAutoWhite() {
        guard let autoWhite, !autoRunning else { return }
        // The estimate is of THIS frame; if the playhead or the group has
        // moved by the time it lands it would write the wrong white into
        // the wrong moment, so it is dropped instead.
        let requestedAt = playheadPosition
        let requestedGroup = group
        Task { @MainActor in
            autoRunning = true
            defer { autoRunning = false }
            guard let estimate = await autoWhite() else { return }
            guard playheadPosition == requestedAt, group == requestedGroup else { return }
            ownWhite(kelvin: estimate.kelvin, tint: estimate.tint)
            autoWhiteWritten = Self.storedWhite(kelvin: estimate.kelvin, tint: estimate.tint)
        }
    }

    /// True while the white under the playhead is still the one Auto wrote.
    /// Within half a mired / half a tint point: a playhead that snapped its
    /// write onto a keyframe reads back the blend a hair beside it.
    private var isAutoWhite: Bool {
        guard let auto = autoWhiteWritten, adjustments.ownsWhite else { return false }
        return abs(adjustments.whiteMired - auto.mired) < 0.5
            && abs(adjustments.whiteTint - auto.tint) < 0.5
    }

    /// A white as `ownWhite` stores it.
    private static func storedWhite(kelvin: Double, tint: Double) -> (mired: Float, tint: Float) {
        (Float(1_000_000 / min(max(kelvin, 1667), 25000)), Float(min(max(tint, -150), 150)))
    }

    /// The white-balance menu. Everything in it writes the *white itself* —
    /// into the moment under the playhead, exactly as dragging the pad
    /// would — because that is the only model in which two keyframes mean
    /// "from this white to that one" whatever the camera did in between. The
    /// one project-level entry is smoothing, which is what a frame renders at
    /// until a keyframe owns its white.
    ///
    /// On the dark editors the menu is a pill drawn here; on the Mac it is the
    /// native `Menu` — a bordered pop-up, which is what the board draws.
    @ViewBuilder private var whiteBalanceMenu: some View {
        if isLight {
            Menu(currentWhiteName) { whiteBalanceMenuItems }
                .font(.system(size: 12.5, weight: .semibold))
                .fixedSize()
                .accessibilityLabel("White balance")
                .accessibilityValue(currentWhiteName)
        } else {
            Menu {
                whiteBalanceMenuItems
            } label: {
                HStack(spacing: 4) {
                    Text(currentWhiteName)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(pillFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            // The title changes with the white ("As Shot", "6715 K"), so
            // without a label VoiceOver cannot tell the menu from a readout.
            .accessibilityLabel("White balance")
            .accessibilityValue(currentWhiteName)
        }
    }

    @ViewBuilder private var whiteBalanceMenuItems: some View {
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

    static let namedIlluminants: [(String, Double)] = [
        ("Sunny", 5500), ("Cloudy", 6500), ("Fluorescent", 4000), ("Tungsten", 3200),
    ]

    private var frameWhiteMired: Float {
        Float(1_000_000 / min(max(frameWhiteKelvin, 1667), 25000))
    }

    /// Owns the white at this moment. Goes through the same binding a pad
    /// drag does, so the owner's timeline logic — keyframe write, seeding of
    /// the other moments — is the same logic.
    private func ownWhite(kelvin: Double, tint: Double) {
        var values = adjustments
        let stored = Self.storedWhite(kelvin: kelvin, tint: tint)
        values.whiteMired = stored.mired
        values.whiteTint = stored.tint
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
            var values = adjustments
            values.whiteMired = 0
            values.whiteTint = 0
            adjustments = values
        }
    }

    /// The menu's closed label: "Auto" while the white is still the
    /// estimate, else the owned white by name or by Kelvin, or what the frame
    /// is taking instead.
    private var currentWhiteName: String {
        guard let white = adjustments.ownedWhite else {
            if case .smoothed = whiteBalanceSource { return "Smoothed" }
            return "As Shot"
        }
        if isAutoWhite { return "Auto" }
        if white.tint == 0, let named = Self.namedIlluminants.first(
            where: { abs($0.1 - Double(white.kelvin)) < 1 }) {
            return named.0
        }
        return "\(Int(white.kelvin.rounded())) K"
    }

    /// Temp: the white itself, read out in Kelvin. The control travels in
    /// mired so equal distances look equal, and is presented negated so the
    /// warm end is up and to the right, where every editor puts it (spec §2:
    /// presented = −mired, top = warm). While nothing owns the white the knob
    /// rests on the frame's own — which is also where the crosshair sits —
    /// and the first move owns it, carrying the frame's tint along so Tint
    /// does not jump to zero. Any write clears the Auto name.
    private var tempAxis: PadAxis {
        let range = PhotoAdjustments.whiteMiredRange
        let presented = -range.upperBound ... -range.lowerBound
        let frameMired = frameWhiteMired
        let frameTint = Float(frameWhiteTint)
        return PadAxis(
            label: "Temp", field: .whiteMired,
            range: presented, neutral: -frameMired,
            isNeutral: { !adjustments.ownsWhite },
            readout: { "\(Int((1_000_000 / Double(-$0)).rounded())) K" },
            get: { -(adjustments.ownsWhite ? adjustments.whiteMired : frameMired) },
            set: { values, presented in
                if !values.ownsWhite { values.whiteTint = frameTint }
                values.whiteMired = min(max(-presented, range.lowerBound), range.upperBound)
            },
            reset: { $0.whiteMired = 0; $0.whiteTint = 0 },
            resetFields: [.whiteMired, .whiteTint],
            track: [EditorPalette.blue, EditorPalette.rgb(0xD8D8DC), EditorPalette.amber])
    }

    /// Tint, on the converter's ±150 axis, green left to magenta right.
    /// Moving it owns the white too — a tint is a property of some white,
    /// never of none.
    private var tintAxis: PadAxis {
        let range = PhotoAdjustments.whiteTintRange
        let frameMired = frameWhiteMired
        let frameTint = Float(frameWhiteTint)
        return PadAxis(
            label: "Tint", field: .whiteTint,
            range: range, neutral: min(max(frameTint, range.lowerBound), range.upperBound),
            isNeutral: { !adjustments.ownsWhite },
            readout: Self.tintReadout,
            get: { adjustments.ownsWhite ? adjustments.whiteTint : frameTint },
            set: { values, tint in
                if !values.ownsWhite { values.whiteMired = frameMired }
                values.whiteTint = min(max(tint, range.lowerBound), range.upperBound)
            },
            reset: { $0.whiteMired = 0; $0.whiteTint = 0 },
            resetFields: [.whiteMired, .whiteTint],
            track: [EditorPalette.green, EditorPalette.rgb(0xD8D8DC), EditorPalette.magenta])
    }

    // MARK: - Color Mixer

    /// The three things the Color Mixer can move about a band.
    private enum MixerLane: CaseIterable {
        case hue, saturation, luminance

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

    /// The panel as stored, or neutral while the grade holds none.
    private var mixerPanel: HSLAdjustments { adjustments.hsl ?? .neutral }

    /// One lane of the selected band. Not a field, so no diamond and never a
    /// timeline reset: writes go through the same binding a pad does, so the
    /// owner's timeline logic — which moment the value belongs to — is the
    /// same logic; a panel that ends up neutral is stored as no panel at all.
    private func mixerAxis(_ label: String, _ lane: MixerLane) -> PadAxis {
        let band = band
        func write(_ value: Float, into values: inout PhotoAdjustments) {
            var panel = values.hsl ?? .neutral
            lane.set(min(max(value, -1), 1), of: band, in: &panel)
            values.hsl = panel.isNeutral ? nil : panel
        }
        return PadAxis(
            label: label, field: nil, range: -1...1, neutral: 0,
            isNeutral: { lane.value(of: band, in: mixerPanel) == 0 },
            readout: Self.defaultReadout,
            get: { lane.value(of: band, in: mixerPanel) },
            set: { values, value in write(value, into: &values) },
            reset: { values in write(0, into: &values) },
            resetFields: [])
    }

    /// The eight bands above the mixer pad: a ring in each band's swatch,
    /// filled when selected; the inner dot is black (white on the Mac) when
    /// selected, the swatch when the band has moved on any lane, else clear.
    private var bandRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(HSLAdjustments.Band.allCases.enumerated()), id: \.element) { index, candidate in
                if index > 0 { Spacer(minLength: 0) }
                bandDot(candidate)
            }
        }
        .padding(.horizontal, isLight ? 2 : 4)
    }

    private func bandDot(_ candidate: HSLAdjustments.Band) -> some View {
        let selected = candidate == band
        let moved = MixerLane.allCases.contains { $0.value(of: candidate, in: mixerPanel) != 0 }
        let swatch = Self.swatch(for: candidate)
        let size: CGFloat = isLight ? 26 : 28
        let dot: Color = selected ? (isLight ? .white : .black) : (moved ? swatch : .clear)
        return Button {
            band = candidate
        } label: {
            Circle()
                .fill(selected ? swatch : Color.clear)
                .overlay(Circle().strokeBorder(swatch, lineWidth: 2.5))
                .overlay(Circle().fill(dot).frame(width: 7, height: 7))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.lightroomName)
        .accessibilityValue(moved ? "adjusted" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The band's colour, for its swatch and the mixer pad: the board's
    /// `hsl(h, 82%, 55%)` at the board's hues — purple and magenta drawn at
    /// 280° / 320° like `EditorToolIcon.mixer`, a few degrees off the Kit's
    /// band centres (275° / 315°), which stay the engine's business.
    static func swatch(for band: HSLAdjustments.Band) -> Color {
        EditorPalette.hsl(boardHueDegrees(for: band), 0.82, 0.55)
    }

    /// The hue the board draws a band at.
    static func boardHueDegrees(for band: HSLAdjustments.Band) -> Double {
        switch band {
        case .purple: return 280
        case .magenta: return 320
        default: return Double(band.centreDegrees)
        }
    }

    // MARK: - Crop

    private var currentAspect: FrameCrop.Aspect { adjustments.crop?.aspect ?? .original }

    @ViewBuilder private var cropContent: some View {
        aspectChips
        Text(cropHint)
            .font(.system(size: 11))
            .foregroundStyle(isLight ? EditorPalette.secondaryOnLight : Color.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        // The one control that is not a colour: the shared `RotationSlider`,
        // in its stacked shape, so a text layer's Angle row and this one are
        // the same instrument. It writes through the same binding as every
        // colour, so the timeline keyframes and eases it exactly like them.
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

    /// Original · 1:1 · 4:5 · 16:9 · 9:16 · Custom, every chip the same width.
    /// Six chips is a tight fit at the Mac card's 274 pt of content: each
    /// chip gets ~42 pt, so the labels are 10.5 pt, may shrink to 0.8, and
    /// keep 2 pt of side padding so "Original" and "Custom" never touch
    /// their chip's edge. The dark editors have 361 pt for the same row and
    /// no such squeeze.
    private var aspectChips: some View {
        HStack(spacing: isLight ? 4 : 5) {
            ForEach(FrameCrop.Aspect.allCases, id: \.self) { aspect in
                aspectChip(aspect)
            }
        }
    }

    private func aspectChip(_ aspect: FrameCrop.Aspect) -> some View {
        let selected = currentAspect == aspect
        let shape = RoundedRectangle(cornerRadius: isLight ? 6 : 12, style: .continuous)
        // Board 3b's `crops()` fills an idle chip `#F2F2F7` on the white
        // card, with the hairline; white-on-white would lose the chip.
        let ink: Color = selected
            ? (isLight ? .white : .black)
            : (isLight ? .primary : .white)
        let fill: Color = selected
            ? accent
            : (isLight ? EditorPalette.chipFillOnLight : Color.white.opacity(0.08))
        return Button {
            select(aspect)
        } label: {
            Text(aspect.label)
                .font(.system(size: isLight ? 10.5 : 11.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(isLight ? 0.8 : 1)
                .foregroundStyle(ink)
                .padding(.horizontal, isLight ? 2 : 0)
                .frame(maxWidth: .infinity)
                .padding(.vertical, isLight ? 5 : 7)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(isLight ? Color.black.opacity(0.08) : Color.clear, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(aspect == .original ? "Original, the whole picture" : "Crop to \(aspect.label)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Original is no crop at all; Custom keeps whatever rectangle is there
    /// and frees its ratio; a ratio fits the largest centred frame of that
    /// shape into the levelled picture. The rectangle itself is then the
    /// picture's business (`CropFrameOverlay`).
    private func select(_ aspect: FrameCrop.Aspect) {
        var values = adjustments
        switch aspect {
        case .original:
            values.crop = nil
        case .custom:
            var crop = values.crop ?? .full
            crop.aspect = .custom
            values.crop = crop
        default:
            values.crop = FrameCrop.fitted(aspect, frameAspect: cropFrameAspect)
        }
        adjustments = values
    }

    private var cropHint: String {
        switch currentAspect {
        case .original: return "Original · the whole picture"
        case .custom: return "Free crop · \(cropNote ?? "drag corners, drag to move, pinch to scale")"
        default: return "Locked to \(currentAspect.label) · \(cropNote ?? "drag to move, pinch or drag a corner to scale")"
        }
    }

    // MARK: - Group state

    private var groupIsNeutral: Bool {
        Self.isNeutral(
            group, adjustments: adjustments, keyframedFields: keyframedFields,
            whiteBalanceSource: whiteBalanceSource, presetState: presets?.presetState)
    }

    /// Whether a group holds a value — the header dot's rule, and the main
    /// buttons' (`EditorGroupBar(nonNeutral:)` asks the same question, which
    /// is why it lives here and is static). A group holding a property that
    /// travels is never neutral, whatever the moment under the playhead
    /// reads.
    ///
    /// - Color counts the owned white AND smoothing (it moves the pixels even
    ///   while nothing owns the white), vibrance, saturation, and the mixer.
    /// - Detail counts `colorNoise`, which no tool shows — a Lightroom import
    ///   can still write it, and the dot has to light for a value the panel
    ///   cannot otherwise reveal.
    /// - Crop counts the rotation and a crop that takes a pixel off; a set
    ///   crop that keeps the whole frame is the same picture.
    /// - Presets is neutral while the project is on Original; with no presets
    ///   to show (a masked grade) it is always neutral.
    static func isNeutral(
        _ group: EditorGroup,
        adjustments: PhotoAdjustments,
        keyframedFields: Set<PhotoAdjustmentField>,
        whiteBalanceSource: WhiteBalanceSource,
        presetState: PresetState?
    ) -> Bool {
        guard keyframedFields.isDisjoint(with: group.fields) else { return false }
        switch group {
        case .presets:
            return presetState?.isOriginal ?? true
        case .color:
            return !adjustments.ownsWhite && whiteBalanceSource.isAsShot
                && adjustments.vibrance == 0 && adjustments.saturation == 0
                && (adjustments.hsl?.isNeutral ?? true)
        case .crop:
            return !adjustments.hasRotation && !adjustments.hasCrop
        case .light, .effects, .detail:
            return group.fields.allSatisfy { adjustments[keyPath: $0.keyPath] == $0.neutralValue }
        }
    }

    /// "Reset <Group>": every value the group holds, back to nothing. Through
    /// the owner field by field when it has a timeline; the values that are
    /// not fields — the mixer, the crop — go out through the binding, which
    /// is where a drag would have put them, in one write.
    private func reset(_ group: EditorGroup) {
        switch group {
        case .presets:
            // Original is the presets' "nothing": the owner's own apply path,
            // which asks first when edits would go with it.
            presets?.onSelect(.builtIn(.original))
        case .color:
            // Resetting Color switches smoothing off as well as releasing the
            // white: "Reset" there has to mean "back to what the camera said".
            onSetWhiteBalanceSource?(.asShot)
            if let onResetField {
                if adjustments.hsl != nil {
                    var values = adjustments
                    values.hsl = nil
                    adjustments = values
                }
                for field in group.fields { onResetField(field) }
            } else {
                var values = adjustments
                values.hsl = nil
                for field in group.fields { values[keyPath: field.keyPath] = field.neutralValue }
                adjustments = values
            }
        case .crop:
            if let onResetField {
                if adjustments.crop != nil {
                    var values = adjustments
                    values.crop = nil
                    adjustments = values
                }
                onResetField(.rotation)
            } else {
                var values = adjustments
                values.crop = nil
                values.rotationDegrees = 0
                adjustments = values
            }
        case .light, .effects, .detail:
            if let onResetField {
                for field in group.fields { onResetField(field) }
            } else {
                var values = adjustments
                for field in group.fields { values[keyPath: field.keyPath] = field.neutralValue }
                adjustments = values
            }
        }
    }

    /// Whether anything would change a pixel — or a moment. `hasCrop`
    /// spelled out beside `isNeutral` because a set-but-full crop keeps its
    /// aspect for the chip yet takes no pixel off.
    private var canResetAll: Bool {
        !adjustments.withoutGeometry.isNeutral || adjustments.hasRotation
            || adjustments.hasCrop || hasKeyframes
    }

    private func resetAll() {
        if let onResetAll {
            onResetAll()
        } else {
            adjustments = .neutral
        }
    }
}

#if DEBUG
private struct PhotoAdjustmentsPanelPreview: View {
    var group: EditorGroup
    var layout: EditorPanelLayout
    var style: XYPadStyle
    @State private var adjustments: PhotoAdjustments = {
        var seed = PhotoAdjustments.neutral
        seed.exposure = 0.3
        seed.contrast = 0.12
        seed.highlights = -0.27
        return seed
    }()
    @State private var tools: [EditorGroup: EditorTool] = [:]
    @StateObject private var cache = PresetThumbnailCache()

    var body: some View {
        PhotoAdjustmentsPanel(
            adjustments: $adjustments, group: group, layout: layout, style: style,
            toolSelection: $tools,
            accent: style == .dark ? LL.amber : LL.accent,
            keyframedFields: [.exposure, .highlights, .whiteMired],
            presets: EditorPresetsContext(
                frame: nil, presetState: .original, basePreset: .original,
                customPresets: [], cache: cache,
                onSelect: { _ in }, onDelete: nil, onSaveAsPreset: {},
                saveOffer: nil, lightroomCard: nil),
            autoWhite: { nil })
    }
}

#Preview("Phone · Light") {
    VStack {
        Spacer()
        PhotoAdjustmentsPanelPreview(group: .light, layout: .phone, style: .dark)
    }
    .frame(width: 393, height: 852)
    .background(Color(red: 0.2, green: 0.25, blue: 0.3))
    .environment(\.colorScheme, .dark)
}

#Preview("Floating · Color") {
    PhotoAdjustmentsPanelPreview(group: .color, layout: .floating, style: .dark)
        .padding(40)
        .background(Color(red: 0.2, green: 0.25, blue: 0.3))
        .environment(\.colorScheme, .dark)
}

#Preview("Mac · Crop") {
    PhotoAdjustmentsPanelPreview(group: .crop, layout: .rail, style: .light)
        .frame(width: 298)
        .padding(16)
        .background(EditorPalette.rgb(0xF2F2F7))
}
#endif

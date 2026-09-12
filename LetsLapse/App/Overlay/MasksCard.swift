import SwiftUI
import LetsLapseKit

/// The Editor tab's Masks card — where a grade gets applied inside a mask.
///
/// It sits under the open group's panel on the rail, and it is closed by
/// default: one strip of thumbnails saying what the picture is carrying —
/// or, on the Mac rail (`compactRows`), one row per grade that also says
/// what each grade DOES, as the tool icons of the whole-picture panel. Click
/// a thumbnail or a row and the card expands into that mask's own
/// adjustments — the same sections and controls as the panel, over a region
/// instead of the frame.
///
/// The division of labour is the design's: **this card owns a mask's grade,
/// the Masks tab owns its shape.** Same mask, two sides of it. Nothing here
/// draws or edits geometry beyond putting the expanded mask's handles on the
/// picture, which the viewer does on this card's behalf.
struct MasksCard: View {
    @Binding var document: OverlayDocument
    /// Which grade is open, or nil for the collapsed card.
    @Binding var expandedGradeID: UUID?
    /// The magenta region tint, shared with the Masks tab's own checkbox.
    @Binding var showMask: Bool
    var accent: Color = LL.accent
    let sources: MaskThumbnails.Sources
    /// Whether the segmentation model is installed. Sky and Land can be added
    /// without it — the grade is stored either way — but they select nothing
    /// until it is there, so the menu says so rather than failing silently.
    let modelInstalled: Bool
    /// Arming a field for the drag-on-the-picture gesture. nil while the
    /// gesture is unavailable (the stacked phone layout, where the picture is
    /// already carrying pan and zoom).
    var armedField: PhotoAdjustmentField?
    var onArmField: ((PhotoAdjustmentField?) -> Void)?
    let onEdited: (_ commit: Bool) -> Void
    /// "Manage ›" and "Manage masks…" — over to the Masks tab, with this
    /// mask selected.
    let onManage: (MaskRef?) -> Void
    /// "New Linear mask…" / "New Radial mask…" — the Masks tab with the tool
    /// already armed, so the next drag on the picture draws one.
    let onNewShape: (MaskShapeKind) -> Void
    /// The Mac rail's compact list (board 3b, rail item 4): one row per
    /// grade — tile, name, kind · enabled, the tool icons its grade lights,
    /// a chevron — in place of the thumbnail strip. Off, the card keeps the
    /// strip exactly as the stacked layouts draw it (the iPhone mask mirror
    /// still specifies that strip). Defaulted per platform so the viewer
    /// needs no edit: the Mac gets the board's rows, every touch layout the
    /// strip. The board is drawn light; the rows take its sizes and the
    /// system's inks (`.primary` / `.secondary`) rather than its hex values,
    /// because the Mac rail follows the system appearance and an `LL.ink`
    /// name on a dark card is invisible (seen 2026-09-12).
    var compactRows: Bool = MasksCard.defaultCompactRows

    /// The board's rows are the Mac rail's; the touch layouts keep the strip.
    static var defaultCompactRows: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !document.maskGrades.isEmpty {
                if compactRows {
                    compactList
                } else {
                    thumbnailStrip
                }
                if let grade = expandedGrade {
                    Divider().padding(.vertical, 2)
                    expandedPanel(for: grade)
                }
            }
        }
        // The board's card is padded 12 like the panel card above it; the
        // strip keeps the 14 its own mirrors were measured at.
        .padding(compactRows ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Masks")
                .font(.system(size: compactRows ? 13.5 : 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if !document.maskGrades.isEmpty {
                // The board sets the count in the caption face; the strip's
                // mirrors were measured with it monospaced.
                if compactRows {
                    Text("\(document.maskGrades.count) applied")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(document.maskGrades.count) applied")
                        .font(.system(size: 11))
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if document.maskGrades.isEmpty {
                addMenu { Text("＋ Add").font(.system(size: 12, weight: .semibold)) }
            } else {
                Button {
                    onManage(expandedGrade?.mask)
                } label: {
                    Text("Manage ›").font(.system(size: compactRows ? 12.5 : 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
            }
        }
    }

    // MARK: - The compact list (Mac rail)

    /// One row per grade, in list order. The board draws no add tile here:
    /// a second grade is added from the Masks tab (Manage ›), which owns the
    /// mask vocabulary on this layout.
    private var compactList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(document.maskGrades) { grade in
                compactRow(for: grade)
            }
        }
    }

    @ViewBuilder private func compactRow(for grade: MaskGrade) -> some View {
        if let mask = document.projectMask(grade.mask) {
            let expanded = expandedGradeID == grade.id
            Button {
                // The same tap as the strip's tile: a second click on the
                // open one closes the card.
                expandedGradeID = expanded ? nil : grade.id
                onArmField?(nil)
            } label: {
                // 8 rather than the board's 10 between the row's parts: the
                // name column is what is left of 274 pt after the tile, four
                // icons and the chevron, and at 10 the longest built-in
                // caption ("Land · AUTO · disabled") lost its last letters
                // (measured 2026-09-12); at 8 it fits with a few points over.
                HStack(spacing: 8) {
                    MaskTile(
                        mask: mask, inverted: grade.inverted,
                        size: CGSize(width: 44, height: 36), sources: sources,
                        isSelected: expanded,
                        isDisabled: !grade.isEnabled, accent: accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mask.name(inverted: grade.inverted))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        // The kind alone under the name — the inversion is
                        // already in the name and on the tile's ⊘, and the
                        // column has about 120 pt beside four icons.
                        // Allowed to shrink a little before it truncates: the
                        // column sits within a few points of the longest
                        // built-in caption, and the rail's scroller takes
                        // those points back once a grade is expanded.
                        Text("\(mask.kind.caption) · \(grade.isEnabled ? "enabled" : "disabled")")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .minimumScaleFactor(0.85)
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    toolIcons(for: grade)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(mask.name(inverted: grade.inverted)) · \(grade.summary)")
            .accessibilityLabel(compactRowLabel(grade, mask: mask))
            .accessibilityAddTraits(expanded ? .isSelected : [])
        }
    }

    /// The grade as tool icons: every tool it moves at full ink, and for
    /// each section it leaves alone that section's first tool at 35 % — the
    /// board's "wb · ec lit, tc dimmed". Dimming every one of the seven
    /// tools a mask can reach would say the same thing in 130 pt, which the
    /// 330 pt rail cannot spare beside the name; one placeholder per silent
    /// section keeps the common row to four icons.
    private func toolIcons(for grade: MaskGrade) -> some View {
        HStack(spacing: 3) {
            ForEach(Self.iconTools(for: grade), id: \.tool) { entry in
                EditorToolIcon(glyph: .tool(entry.tool), ink: .primary, size: 16)
                    .opacity(entry.touched ? 1 : 0.35)
            }
        }
        .accessibilityHidden(true)
    }

    /// The row's icons, in `MaskGrade.tools` order: the touched tools, plus
    /// one dimmed lead tool per section nothing in it has moved.
    static func iconTools(for grade: MaskGrade) -> [(tool: EditorTool, touched: Bool)] {
        let touched = grade.touchedTools
        var placeholders: [EditorTool] = []
        for section in MaskGrade.sections {
            let sectionTools = section.fields.compactMap(MaskGrade.tool(for:))
            guard !sectionTools.contains(where: touched.contains),
                  let lead = sectionTools.first else { continue }
            placeholders.append(lead)
        }
        return MaskGrade.tools.compactMap { tool in
            if touched.contains(tool) { return (tool, true) }
            if placeholders.contains(tool) { return (tool, false) }
            return nil
        }
    }

    private func compactRowLabel(_ grade: MaskGrade, mask: ProjectMask) -> String {
        var parts = [
            mask.name(inverted: grade.inverted),
            mask.caption(inverted: grade.inverted),
            grade.isEnabled ? "enabled" : "disabled",
        ]
        let tools = grade.touchedTools.map(\.title)
        parts.append(tools.isEmpty ? "no adjustments yet" : "adjusts " + tools.joined(separator: ", "))
        return parts.joined(separator: ", ")
    }

    // MARK: - The strip

    private var thumbnailStrip: some View {
        FlowRow(spacing: 8, lineSpacing: 6.5) {
            ForEach(document.maskGrades) { grade in
                thumbnail(for: grade)
            }
            addMenu {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accent.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(accent.opacity(0.5),
                                          style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .overlay(Text("＋").font(.system(size: 15, weight: .semibold)))
                    .frame(width: 48, height: 36)
            }
        }
    }

    @ViewBuilder private func thumbnail(for grade: MaskGrade) -> some View {
        if let mask = document.projectMask(grade.mask) {
            Button {
                // A second click on the open one closes the card, which is
                // the only way back to the strip without picking another.
                expandedGradeID = expandedGradeID == grade.id ? nil : grade.id
                onArmField?(nil)
            } label: {
                MaskTile(
                    mask: mask, inverted: grade.inverted,
                    size: CGSize(width: 48, height: 36), sources: sources,
                    isSelected: expandedGradeID == grade.id,
                    isDisabled: !grade.isEnabled, accent: accent)
            }
            .buttonStyle(.plain)
            .help("\(mask.name(inverted: grade.inverted)) · \(grade.summary)")
        }
    }

    // MARK: - Add menu

    /// Every mask, twice: as created and inverted. A version that is already
    /// in the card reads "✓ added" and re-opens the grade it has rather than
    /// making a second one — the (mask, inverted) uniqueness rule, said out
    /// loud in the menu so it never looks like a failed click.
    ///
    /// A native `Menu`: it is a menu on both platforms, and on the Mac it
    /// inherits the real thing — keyboard driving, dismissal, submenus.
    private func addMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.masks) { mask in
                        addButton(for: mask, inverted: false)
                        addButton(for: mask, inverted: true)
                    }
                }
            }
            Divider()
            Button("New Linear mask…") { onNewShape(.linear) }
            Button("New Radial mask…") { onNewShape(.radial) }
            Button("Manage masks…") { onManage(nil) }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(accent)
    }

    @ViewBuilder private func addButton(for mask: ProjectMask, inverted: Bool) -> some View {
        let existing = document.maskGrade(for: mask.ref, inverted: inverted)
        Button {
            let id = document.addMaskGrade(for: mask.ref, inverted: inverted)
            expandedGradeID = id
            onArmField?(nil)
            onEdited(true)
        } label: {
            // The ✓ is the menu's own idiom for "this one is already on".
            Label {
                Text(existing == nil
                     ? mask.name(inverted: inverted)
                     : "\(mask.name(inverted: inverted))  ✓ added")
            } icon: {
                if let image = MaskThumbnails.image(
                    for: mask, inverted: inverted,
                    size: CGSize(width: 22, height: 16), sources: sources) {
                    Image(decorative: image, scale: 1).resizable()
                }
            }
        }
    }

    /// The menu's three groups, in the design's order. A group with nothing
    /// in it is left out rather than shown empty.
    private var groups: [(title: String, masks: [ProjectMask])] {
        let all = document.projectMasks
        var out: [(String, [ProjectMask])] = []
        let semantic = all.filter { $0.kind.isAuto }
        if !semantic.isEmpty {
            out.append((modelInstalled
                        ? "Intelligent · Auto"
                        : "Intelligent · Auto (model not installed)", semantic))
        }
        let custom = all.filter { $0.kind == .custom }
        if !custom.isEmpty { out.append(("Custom", custom)) }
        let shapes = all.filter { if case .shape = $0.kind { return true } else { return false } }
        if !shapes.isEmpty { out.append(("Shapes", shapes)) }
        return out
    }

    // MARK: - Expanded grade

    private var expandedGrade: MaskGrade? {
        expandedGradeID.flatMap { document.maskGrade(id: $0) }
    }

    private func binding(for id: UUID) -> Binding<MaskGrade>? {
        guard let index = document.maskGrades.firstIndex(where: { $0.id == id }) else { return nil }
        return $document.maskGrades[index]
    }

    @ViewBuilder private func expandedPanel(for grade: MaskGrade) -> some View {
        if let bound = binding(for: grade.id), let mask = document.projectMask(grade.mask) {
            VStack(alignment: .leading, spacing: 12) {
                gradeHeader(bound, mask: mask)
                gradeToggles(bound)
                ForEach(MaskGrade.sections, id: \.title) { section in
                    MaskGradeSection(
                        grade: bound, title: section.title, fields: section.fields,
                        accent: accent, armedField: armedField, onArmField: onArmField,
                        onEdited: onEdited)
                }
                Text("Applied inside this mask only, over the whole shoot. Stored as parameters, rendered live — nothing is baked in.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func gradeHeader(_ grade: Binding<MaskGrade>, mask: ProjectMask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(mask.name(inverted: grade.wrappedValue.inverted))
                    .font(.system(size: 15, weight: .bold))
                Text(mask.caption(inverted: grade.wrappedValue.inverted))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !grade.wrappedValue.adjustments.isColorNeutral {
                Button("Reset") {
                    grade.wrappedValue.adjustments = .neutral
                    onEdited(true)
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .buttonStyle(.plain)
            }
            Button {
                expandedGradeID = nil
                onArmField?(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(LL.controlFill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close this mask's grade")
        }
    }

    private func gradeToggles(_ grade: Binding<MaskGrade>) -> some View {
        HStack(spacing: 16) {
            Toggle(isOn: Binding(
                get: { grade.wrappedValue.isEnabled },
                set: { grade.wrappedValue.isEnabled = $0; onEdited(true) })) {
                Text("Enabled").font(.system(size: 13.5, weight: .semibold))
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            .tint(accent)
            .fixedSize()

            Toggle(isOn: Binding(
                get: { showMask },
                set: { showMask = $0; onEdited(false) })) {
                Text("Show mask").font(.system(size: 13.5, weight: .semibold))
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            .tint(accent)
            .fixedSize()

            Spacer(minLength: 0)

            Button("Remove") {
                let id = grade.wrappedValue.id
                expandedGradeID = nil
                onArmField?(nil)
                document.removeMaskGrade(id: id)
                onEdited(true)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
    }
}

/// One section of a masked grade — the same shape as
/// `PhotoAdjustmentsPanel`'s, with the two differences a masked grade needs:
/// a smaller field list, and a label that can be **armed** so the next
/// vertical drag on the picture moves it.
struct MaskGradeSection: View {
    @Binding var grade: MaskGrade
    let title: String
    let fields: [PhotoAdjustmentField]
    var accent: Color = LL.accent
    var armedField: PhotoAdjustmentField?
    var onArmField: ((PhotoAdjustmentField?) -> Void)?
    let onEdited: (_ commit: Bool) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !isNeutral {
                    Circle().fill(accent).frame(width: 6, height: 6)
                }
                Spacer()
                if !isNeutral {
                    Button("Reset") {
                        grade.reset(fields: fields)
                        onEdited(true)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                    .buttonStyle(.plain)
                }
            }
            ForEach(fields, id: \.self) { field in
                row(field)
            }
        }
    }

    private var isNeutral: Bool { fields.allSatisfy { grade.isNeutral($0) } }

    private func row(_ field: PhotoAdjustmentField) -> some View {
        let value = $grade.adjustments[dynamicMember: field.keyPath]
        let neutral = grade.isNeutral(field)
        let armed = armedField == field
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(Self.label(for: field))
                    .font(.system(size: 13.5, weight: armed ? .semibold : .regular))
                    .foregroundStyle(armed ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                if armed {
                    Text("DRAG ↕")
                        .font(.system(size: 9.5, weight: .bold))
                        .monospaced()
                        .foregroundStyle(LL.ink)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(LL.amber, in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                Text(Self.readout(field, value.wrappedValue))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
            }
            .contentShape(Rectangle())
            // A single click arms the label for the drag gesture; a double
            // click resets the field, the idiom the whole-picture panel
            // already teaches. Order matters — the double-tap modifier has to
            // come first or the single one swallows it.
            .onTapGesture(count: 2) {
                value.wrappedValue = field.neutralValue
                onArmField?(nil)
                onEdited(true)
            }
            .onTapGesture {
                guard onArmField != nil else { return }
                onArmField?(armed ? nil : field)
            }
            Slider(
                value: value,
                in: MaskGrade.range(for: field)
            ) { editing in
                onEdited(!editing)
            }
            .tint(accent)
            .accessibilityLabel(armed ? "\(Self.label(for: field)), armed for drag"
                                      : Self.label(for: field))
        }
    }

    /// A masked grade's labels. Temp is the odd one: inside a mask it is a
    /// RELATIVE warmth, not the absolute white the whole-picture panel now
    /// declares — see `MaskGradeSection.readout`.
    static func label(for field: PhotoAdjustmentField) -> String {
        switch field {
        case .temperature: return "Temp"
        case .tint: return "Tint"
        case .exposure: return "Exposure"
        case .contrast: return "Contrast"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .saturation: return "Saturation"
        case .clarity: return "Clarity"
        case .vignetteIntensity: return "Vignette"
        case .vignetteMidpoint: return "Midpoint"
        default: return field.rawValue.capitalized
        }
    }

    static func readout(_ field: PhotoAdjustmentField, _ value: Float) -> String {
        switch field {
        case .exposure:
            return value == 0 ? "0" : String(format: "%+.2f", value)
        case .vignetteMidpoint:
            // Unipolar 0…100 with 50 in the middle, never signed. Masks do
            // not offer it today; the arm keeps the readout honest if one does.
            return String(format: "%.0f", value * 100)
        case .temperature:
            // Mired, shown as the Kelvin shift it is worth at daylight — the
            // number a photographer can reason about. Positive warms, so the
            // Kelvin moves the other way and the sign is flipped back here.
            guard value != 0 else { return "0" }
            let kelvin = 1_000_000 / max(1e6 / 6500 - Double(value), 1) - 6500
            return String(format: "%+.0f K", kelvin)
        case .tint:
            return value == 0 ? "0" : String(format: "%+.0f", value)
        default:
            return value == 0 ? "0" : String(format: "%+.0f", value * 100)
        }
    }
}

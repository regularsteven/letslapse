import LetsLapseKit
import SwiftUI
import UniformTypeIdentifiers

/// The control sizes the Text tab draws at: pointer-sized on the Mac,
/// finger-sized on iPhone and iPad. Points, straight off the design pass
/// *"Photo viewer text transitions"* (Text Workflow · Mac/iPad, Text
/// Workflow iOS).
enum OverlayPanelMetrics {
    #if os(iOS)
    static let row: CGFloat = 44
    static let segment: CGFloat = 34
    static let chip: CGFloat = 32
    static let chipFont: CGFloat = 12.5
    static let chipPadding: CGFloat = 13
    static let face: CGFloat = 34
    static let faceRadius: CGFloat = 8
    static let setButton: CGFloat = 48
    static let swatch: CGFloat = 22
    static let toolbarSwatch: CGFloat = 20
    static let toolbarButton: CGFloat = 30
    static let remove: CGFloat = 44
    static let add: CGFloat = 50
    static let field: CGFloat = 34
    static let fieldRadius: CGFloat = 8
    static let copyFieldMinHeight: CGFloat = 38
    #else
    static let row: CGFloat = 38
    static let segment: CGFloat = 26
    static let chip: CGFloat = 24
    static let chipFont: CGFloat = 11.5
    static let chipPadding: CGFloat = 10
    static let face: CGFloat = 26
    static let faceRadius: CGFloat = 7
    static let setButton: CGFloat = 40
    static let swatch: CGFloat = 16
    static let toolbarSwatch: CGFloat = 14
    static let toolbarButton: CGFloat = 22
    static let remove: CGFloat = 36
    static let add: CGFloat = 44
    static let field: CGFloat = 26
    static let fieldRadius: CGFloat = 7
    static let copyFieldMinHeight: CGFloat = 30
    #endif

    /// The fill behind compact controls — the design's `#F2F2F7` on the
    /// Mac's light window, `#2C2C2E` on the dark editors.
    static var controlFill: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemGroupedBackground)
        #else
        LL.screenBackground
        #endif
    }
}

/// The Text tab: a list of text layers, front-to-back, each opening into its
/// own copy, type, placement and reveal controls.
///
/// Owns no document state: the editor holds the overlay document and
/// everything here goes back through `onEdited` — `commit: true` for finished
/// gestures (persist + render), `false` for live motion (render only).
/// Disclosure and selection ARE held here, because which card is open
/// describes the editor, not the piece.
///
/// Rebuilt 2026-09-03 from the Claude Design pass *"Photo viewer text
/// transitions"*: reveal in and reveal out with Element · Word · Character
/// units and style chips, "Starts: At time · After layer" sequencing, a
/// rich copy field with a select-to-style toolbar, font import, and the
/// layer ID. Intelligent placement stays exactly as it shipped.
struct OverlayEditingPanel: View {
    @Binding var document: OverlayDocument
    /// The layer the preview draws chrome around. Shared with the viewer.
    @Binding var selectedID: UUID?
    /// True when this capture has length — the only case a reveal can mean
    /// anything.
    let hasTimeline: Bool
    /// The playhead, for Set Start / Set End.
    let position: Double
    /// Formats a position the way the strip does, so "Start" and the
    /// timeline bubble speak the same clock.
    let label: (Double) -> String
    /// Formats a span of the shoot ("40s", "2:10") for the readouts.
    let durationLabel: (Double) -> String
    /// One frame as a fraction of the shoot — the offset stepper's step. 0
    /// when the shoot has no frame count to speak of.
    let frameStep: Double
    let accent: Color
    /// Label colour over the accent — black on the editors' amber, white on
    /// the Mac's accent.
    let onAccent: Color
    /// The source frame's long edge in pixels, so the size readout is a real
    /// number about the delivered file rather than a preview-relative one.
    let frameLongEdgePixels: Double
    /// Frame aspect (w ÷ h), for resolving auto-size the same way the
    /// rasterizer will.
    let frameAspect: Double
    /// The faces this project brought with it (`fonts/`), already registered.
    let importedFonts: [OverlayFontStore.ImportedFont]
    let onEdited: (_ commit: Bool) -> Void
    /// "Custom" on the placement row is a route to the Masks tab, not a value.
    let onOpenMasks: () -> Void
    /// A picked TTF/OTF to copy into the project.
    let onImportFont: (URL) -> Void
    /// A short confirmation to float over the media (`Linked — starts after …`).
    let onToast: (String) -> Void
    /// Whether the Crafted Text sheet is up. Owned by the editor so a launch
    /// hook can open it for a screenshot, the same way `runTarget` is.
    @Binding var isCrafting: Bool
    /// Which copy field is being edited and which of its characters the run
    /// toolbar styles. Owned by the editor, because on iOS the toolbar is
    /// drawn as the keyboard's accessory bar — pinned above the keyboard by
    /// the editor's own safe-area inset, outside this scrolling panel.
    @Binding var runTarget: OverlayRunTarget?

    /// Which cards and sections are open. Keyed by layer, so opening one
    /// layer's TYPE section does not open every layer's.
    @State private var expanded: Set<UUID> = []
    @State private var openSections: Set<SectionKey> = []
    /// Layers whose disclosure defaults have been applied. Without this a
    /// layer seeded from the sidecar would open with every section shut,
    /// and the text — the thing you came to edit — would be two taps away.
    @State private var seededDefaults: Set<UUID> = []
    @State private var morePanelID: UUID?
    @State private var fontPickerID: UUID?
    @State private var parentPickerID: UUID?
    @State private var isImportingFont = false
    /// The Auto-Size explainer, behind its (i) — the popover stays short
    /// until someone asks what the checkbox means.
    @State private var showAutoInfo = false
    @State private var draggingID: UUID?

    /// The text field's focus — held here so the keyboard has real ways OUT
    /// on iOS: the keyboard toolbar's Done, and the editor resigning focus
    /// when the user moves on to dragging or scrubbing
    /// (`PhotoViewerView.dismissTextEntry`).
    @FocusState private var focusedLayer: UUID?

    private struct SectionKey: Hashable {
        let layer: UUID
        let section: Section
    }

    private enum Section: Hashable, CaseIterable {
        case text, type, placement, revealIn, revealOut

        var title: String {
            switch self {
            case .text: return "TEXT"
            case .type: return "TYPE"
            case .placement: return "INTELLIGENT PLACEMENT"
            case .revealIn: return "REVEAL IN"
            case .revealOut: return "REVEAL OUT"
            }
        }
    }

    /// The faces the type picker offers. A curated list, not every installed
    /// family: the point is a handful of good, universally present choices.
    /// nil family = the system face. Imported faces follow, under a divider.
    private static let fontChoices: [(label: String, family: String?)] = [
        ("SF Pro", nil),
        ("Helvetica Neue", "Helvetica Neue"),
        ("Georgia", "Georgia"),
        ("Avenir Next", "Avenir Next"),
        ("Futura", "Futura"),
        ("Courier New", "Courier New"),
    ]

    private static let swatches: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"),
        ("Ink", "#1C1C1E"),
        ("Accent", "#C36A00"),
        ("Amber", "#FFB340"),
        ("Lemon", "#F3E37C"),
        ("Charcoal", "#3A3A3C"),
    ]

    private typealias M = OverlayPanelMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            craftButton
            header
            VStack(spacing: 10) {
                ForEach($document.overlays) { $layer in
                    layerCard($layer)
                }
            }
            .task(id: document.overlays.map(\.id)) { seedSectionDefaults() }
            addButton
            footnote(footnoteCopy)
        }
        .sheet(isPresented: $isCrafting) {
            CraftedTextSheet(accent: accent, onAccent: onAccent, onAdd: addCrafted)
        }
        .fileImporter(
            isPresented: $isImportingFont,
            allowedContentTypes: [.font],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                onImportFont(url)
            }
        }
    }

    private var footnoteCopy: String {
        guard hasTimeline else {
            return "Drag the text on the preview to place it. Drag a layer by its grip to reorder — the top layer sits in front."
        }
        #if os(iOS)
        return "Get the layout right first, then time the reveals. Drag any text on the preview to place it; layers that follow it move with it. Touch and hold a text to link it. Drag a band in the lanes to move it in time. Tap a word in the field to style just that word."
        #else
        return "Get the layout right first, then time the reveals. Drag any text on the preview to place it; layers that follow it move with it. Right-click or ⌃-click a text to link it. Drag a band in the lanes to move it in time. The top layer sits in front."
        #endif
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Text Layers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(document.overlays.count) \(document.overlays.count == 1 ? "layer" : "layers")")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    /// "Add Crafted Text" — above the list, always there, because it is how
    /// a piece of copy becomes several timed layers rather than a thing you
    /// reach for once. Ink and a spark, so it does not compete with the
    /// accent-on-card Add Text below the list.
    private var craftButton: some View {
        Button {
            isCrafting = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(LL.amber)
                Text("Add Crafted Text")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: M.add)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 8)
        .accessibilityLabel("Add crafted text")
    }

    /// Lays the parts out and inserts them as linked layers. The typography
    /// is `CraftedTextLayout`'s; measuring is Core Text's, so the fit is
    /// against the face that will actually draw the line.
    private func addCrafted(_ parts: [CraftedTextPart]) {
        let lines = CraftedTextLayout.lines(
            for: parts, aspect: frameAspect,
            measure: { copy, style in
                TextOverlayRasterizer.emWidth(
                    of: copy, family: craftedFont(for: style.role), isBold: style.isBold)
            })
        let made = document.addCrafted(
            lines, at: position, hasTimeline: hasTimeline,
            fontFor: craftedFont(for:))
        guard let first = made.first else { return }
        selectedID = first
        expanded.insert(first)
        edit(true)
        onToast(made.count == 1
            ? "1 line added"
            : "\(made.count) lines added · each follows the one above")
    }

    /// The design's three display faces stood in for IMPORTED fonts, so a
    /// role resolves against what this project actually brought with it:
    /// the first imported face carries the payoff line, a second (when there
    /// is one) the lines around it, and the quiet lines stay in the system
    /// face, which is already a good quiet sans.
    private func craftedFont(for role: CraftedTextFontRole) -> String? {
        let families = importedFonts.map(\.family)
        switch role {
        case .display: return families.first
        case .hand: return families.count > 1 ? families[1] : families.first
        case .sans: return nil
        }
    }

    private var addButton: some View {
        Button {
            var layer = SceneOverlay(content: .text(.init(string: "Your text")))
            layer.size = 0.08
            layer.centerY = 0.62
            // A shoot with length opens the reveal at the playhead: a 6%
            // fade in, whole element, no exit.
            if hasTimeline { layer.animation = .seeded(at: position) }
            // New layers go to the FRONT of the list, which is the front of
            // the stack: the thing just added is the thing being worked on.
            document.overlays.insert(layer, at: 0)
            selectedID = layer.id
            expanded.insert(layer.id)
            openSections.insert(SectionKey(layer: layer.id, section: .text))
            openSections.insert(SectionKey(layer: layer.id, section: .type))
            if hasTimeline { openSections.insert(SectionKey(layer: layer.id, section: .revealIn)) }
            edit(true)
        } label: {
            Label("Add Text", systemImage: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: M.add)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Every edit funnels through here. The owner resolves sequencing and
    /// re-renders; a commit also persists.
    private func edit(_ commit: Bool) {
        onEdited(commit)
    }

    // MARK: - Layer card

    @ViewBuilder private func layerCard(_ layer: Binding<SceneOverlay>) -> some View {
        let id = layer.wrappedValue.id
        let isSelected = selectedID == id
        VStack(spacing: 0) {
            layerHeader(layer)
            if expanded.contains(id) {
                layerBody(layer)
            }
        }
        .background(LL.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? accent.opacity(0.55) : .clear, lineWidth: 1))
        .shadow(
            color: .black.opacity(draggingID == id ? 0.18 : 0.05),
            radius: draggingID == id ? 10 : 1.5,
            y: draggingID == id ? 6 : 1)
        .opacity(draggingID == id ? 0.94 : 1)
    }

    @ViewBuilder private func layerHeader(_ layer: Binding<SceneOverlay>) -> some View {
        let value = layer.wrappedValue
        let id = value.id
        HStack(spacing: 8) {
            grip(for: id)
            visibilityToggle(layer)
            rowTitle(value)
            if value.animation?.follows != nil {
                linkedBadge
            }
            animationGlyph(value)
            onionToggle(layer)
            expandChevron(id)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: M.row)
        .background(isSelectedBackground(id))
        .contentShape(Rectangle())
        // The same association menu the text on the picture carries, for
        // when the row is what is under the finger.
        .contextMenu {
            OverlayAssociationMenu(
                document: $document, layerID: id,
                onEdited: {
                    selectedID = id
                    edit(true)
                },
                onToast: onToast)
        }
        .onTapGesture { selectedID = id }
    }

    /// The ID when the user gave one, with the copy after it at half
    /// strength; else the copy itself.
    private func rowTitle(_ value: SceneOverlay) -> some View {
        let hasLabel = !value.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let primary = value.isVisible ? Color.primary : Color.secondary
        return (Text(value.displayName).font(.system(size: 13, weight: .semibold))
            + (hasLabel
                ? Text(" · \(value.listTitle)").font(.system(size: 13, weight: .regular))
                    .foregroundColor(primary.opacity(0.5))
                : Text("")))
            .foregroundStyle(primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Starts after another layer."
    private var linkedBadge: some View {
        Image(systemName: "arrow.turn.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(accent)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(accent.opacity(0.1)))
            .help("Starts after another layer")
            .accessibilityLabel("Linked")
    }

    private func isSelectedBackground(_ id: UUID) -> Color {
        selectedID == id ? accent.opacity(0.06) : .clear
    }

    /// Reorder by grip. List order IS stacking order, so this drag is the
    /// only way to say what sits in front of what.
    private func grip(for id: UUID) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(draggingID == id ? accent : Color.secondary.opacity(0.55))
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
            .help("Drag to reorder — the top layer sits in front")
            .gesture(reorderGesture(for: id))
    }

    /// A row-height drag: each row of travel moves the layer one seat.
    /// Measuring live against the real card frames would need a coordinate
    /// space the panel does not own; a fixed step is predictable and, with
    /// the cards this size, lands where the pointer is.
    private func reorderGesture(for id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { gesture in
                draggingID = id
                guard let from = document.overlays.firstIndex(where: { $0.id == id })
                else { return }
                let step = Int((gesture.translation.height / 44).rounded())
                let to = min(max(from + step, 0), document.overlays.count - 1)
                guard to != from else { return }
                let moved = document.overlays.remove(at: from)
                document.overlays.insert(moved, at: to)
                selectedID = id
                edit(false)
            }
            .onEnded { _ in
                draggingID = nil
                edit(true)
            }
    }

    private func visibilityToggle(_ layer: Binding<SceneOverlay>) -> some View {
        let visible = layer.wrappedValue.isVisible
        return Button {
            layer.wrappedValue.isVisible.toggle()
            edit(true)
        } label: {
            Image(systemName: visible ? "eye" : "eye.slash")
                .font(.system(size: 12))
                .foregroundStyle(visible ? Color.primary : Color.secondary.opacity(0.55))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle layer visibility")
        .accessibilityLabel(visible ? "Hide layer" : "Show layer")
    }

    /// A read-only indicator: whether this layer has a reveal, and which.
    private func animationGlyph(_ layer: SceneOverlay) -> some View {
        let on = layer.hasReveal
        return Image(systemName: on ? "wand.and.stars" : "wand.and.stars.inverse")
            .font(.system(size: 12))
            .foregroundStyle(on ? accent : Color.secondary.opacity(0.4))
            .frame(width: 18, height: 18)
            .help(on ? "Reveal: \(revealSummary(layer))" : "Reveal: cut")
            .accessibilityHidden(true)
    }

    private func revealSummary(_ layer: SceneOverlay) -> String {
        let animation = layer.effectiveAnimation
        var parts: [String] = []
        parts.append("\(animation.reveal.unit.displayName) · \(animation.reveal.style?.displayName ?? "Cut") in")
        if let exit = animation.exit {
            parts.append("\(exit.style?.displayName ?? "Cut") out")
        } else {
            parts.append("holds")
        }
        return parts.joined(separator: " · ")
    }

    /// Onion skin only means something against a reveal: with none the text
    /// is always drawn, so there is nothing to see through.
    private func onionToggle(_ layer: Binding<SceneOverlay>) -> some View {
        let value = layer.wrappedValue
        let disabled = !value.hasReveal
        let on = value.onionSkin && !disabled
        return Button {
            guard !disabled else { return }
            layer.wrappedValue.onionSkin.toggle()
            edit(true)
        } label: {
            Image(systemName: "circle.dashed")
                .font(.system(size: 12))
                .foregroundStyle(
                    disabled ? Color.secondary.opacity(0.25)
                        : (on ? Color.white : Color.secondary))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(on ? LL.amber : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled
            ? "Onion skin needs a reveal — with a cut the text is always drawn"
            : "Onion skin: draw the text at full opacity, ignoring the reveal")
    }

    private func expandChevron(_ id: UUID) -> some View {
        let open = expanded.contains(id)
        return Button {
            if open { expanded.remove(id) } else { expanded.insert(id) }
            selectedID = id
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(open ? M.controlFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Collapse layer" : "Expand layer")
    }

    // MARK: - Layer body

    @ViewBuilder private func layerBody(_ layer: Binding<SceneOverlay>) -> some View {
        let id = layer.wrappedValue.id
        VStack(alignment: .leading, spacing: 0) {
            divider
            sectionHeader(.text, layer: id)
            if isOpen(.text, id) { textSection(layer) }
            divider
            sectionHeader(.type, layer: id)
            if isOpen(.type, id) { typeSection(layer) }
            divider
            sectionHeader(.placement, layer: id)
            if isOpen(.placement, id) { placementSection(layer) }
            if hasTimeline {
                divider
                sectionHeader(.revealIn, layer: id) {
                    Text(revealInSummary(layer.wrappedValue))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if isOpen(.revealIn, id) { revealInSection(layer) }
                divider
                sectionHeader(.revealOut, layer: id) {
                    MiniToggle(
                        isOn: Binding(
                            get: { layer.wrappedValue.animation?.exit != nil },
                            set: { on in setExit(layer, on: on) }),
                        accent: accent)
                }
                if isOpen(.revealOut, id) { revealOutSection(layer) }
            }
            divider
            idRow(layer)
            divider
            removeButton(id)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 2)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, -12)
            .padding(.bottom, 10)
    }

    private func isOpen(_ section: Section, _ id: UUID) -> Bool {
        openSections.contains(SectionKey(layer: id, section: section))
    }

    /// A layer arrives with its text section open — that is what the card is
    /// for. Everything else starts shut so a four-layer project is still a
    /// list rather than a wall.
    private func seedSectionDefaults() {
        for layer in document.overlays where !seededDefaults.contains(layer.id) {
            seededDefaults.insert(layer.id)
            openSections.insert(SectionKey(layer: layer.id, section: .text))
        }
    }

    private func sectionHeader(_ section: Section, layer id: UUID) -> some View {
        sectionHeader(section, layer: id) { EmptyView() }
    }

    /// A disclosure row. The trailing slot carries the reveal-in readout and
    /// the reveal-out toggle; it sits outside the disclosure button so a tap
    /// on the toggle is a toggle, not a fold.
    private func sectionHeader<Trailing: View>(
        _ section: Section, layer id: UUID, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let key = SectionKey(layer: id, section: section)
        let open = openSections.contains(key)
        return HStack(spacing: 6) {
            Button {
                if open { openSections.remove(key) } else { openSections.insert(key) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.bottom, 8)
    }

    // MARK: Text

    @ViewBuilder private func textSection(_ layer: Binding<SceneOverlay>) -> some View {
        let value = layer.wrappedValue
        let id = value.id
        VStack(alignment: .leading, spacing: 9) {
            OverlayCopyField(
                text: Binding(
                    get: { layer.wrappedValue.text },
                    set: { layer.wrappedValue.text = $0 }),
                focused: $focusedLayer,
                layerID: id,
                onTarget: { target in
                    // Each field reports only its own caret. A nil from a
                    // field that is not the current target (it just lost
                    // focus to another) must not wipe the new field's word.
                    if let target {
                        runTarget = OverlayRunTarget(layer: id, range: target)
                    } else if runTarget?.layer == id {
                        runTarget?.range = nil
                    }
                },
                onEditingChanged: { edit(false) })
                .onChange(of: focusedLayer) { _, next in
                    // Focus opens the accessory bar (iOS) with the whole
                    // layer as its target; leaving closes it.
                    if next == id {
                        if runTarget?.layer != id { runTarget = OverlayRunTarget(layer: id, range: nil) }
                    } else if runTarget?.layer == id {
                        runTarget = nil
                    }
                }

            #if os(macOS)
            if runTarget?.layer == id, let target = runTarget?.range, !target.isEmpty {
                runToolbar(layer, target: target)
            }
            #endif

            HStack(spacing: 8) {
                Text("Mode")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                segmentRow(
                    OverlayLayoutMode.allCases.map(\.displayName),
                    selectedIndex: OverlayLayoutMode.allCases.firstIndex(of: value.mode) ?? 0
                ) { index in
                    layer.wrappedValue.mode = OverlayLayoutMode.allCases[index]
                    edit(true)
                }
                Spacer(minLength: 4)
                Text(value.mode == .box ? "Drag the box on the preview" : "Flows from the anchor")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }

            sizeRow(layer)
            // The same instrument the Edit screen levels the whole picture
            // with, turning this one layer about its anchor.
            RotationSlider(
                label: "Angle",
                degrees: Binding(
                    get: { layer.wrappedValue.rotationDegrees },
                    set: { next in
                        layer.wrappedValue.rotationDegrees = next
                        edit(false)
                    }),
                style: .inline,
                accent: accent,
                onEditing: { editing in
                    if !editing { edit(true) }
                })
        }
        .padding(.bottom, 12)
    }

    /// The Mac's mini toolbar: an ink bar directly under the copy field,
    /// naming the run it styles.
    @ViewBuilder private func runToolbar(_ layer: Binding<SceneOverlay>, target: Range<Int>) -> some View {
        let text = Array(layer.wrappedValue.text)
        let excerpt = String(text[max(0, target.lowerBound)..<min(target.upperBound, text.count)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 6) {
            Text("“\(excerpt)”")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            runToolbarControls(layer, compact: false)
            Button {
                runTarget?.range = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done styling this word")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LL.ink))
        .transition(.opacity)
    }

    /// B · U · six swatches, acting on the run target — or, with none, on
    /// the whole layer. Shared with the iOS accessory bar.
    private func runToolbarControls(_ layer: Binding<SceneOverlay>, compact: Bool) -> some View {
        OverlayRunToolbarControls(
            layer: layer,
            range: runTarget?.layer == layer.wrappedValue.id ? runTarget?.range : nil,
            accent: accent, onAccent: onAccent, compact: compact,
            onEdited: { edit(true) })
    }

    @ViewBuilder private func sizeRow(_ layer: Binding<SceneOverlay>) -> some View {
        let value = layer.wrappedValue
        let auto = value.mode == .box && value.autoSize
        let resolved = TextOverlayRasterizer.resolvedSize(for: value, aspect: frameAspect)
        HStack(spacing: 8) {
            Text("Size")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Slider(
                value: Binding(
                    get: { layer.wrappedValue.size },
                    set: { next in
                        layer.wrappedValue.size = next
                        edit(false)
                    }),
                in: 0.02...0.22
            ) { editing in
                if !editing { edit(true) }
            }
            .tint(accent)
            .disabled(auto)
            .opacity(auto ? 0.45 : 1)
            Text("\(Int((resolved * frameLongEdgePixels).rounded())) px")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(auto ? LL.amber : accent)
                .frame(width: 58, alignment: .trailing)
        }
    }

    // MARK: Type

    @ViewBuilder private func typeSection(_ layer: Binding<SceneOverlay>) -> some View {
        if let style = layer.wrappedValue.textStyle {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    fontPicker(layer, style: style)
                    faceButton("B", on: style.isBold, weight: .heavy) {
                        layer.wrappedValue.textStyle?.isBold.toggle()
                        edit(true)
                    }
                    faceButton("I", on: style.isItalic, italic: true) {
                        layer.wrappedValue.textStyle?.isItalic.toggle()
                        edit(true)
                    }
                    faceButton("U", on: style.isUnderlined, underline: true) {
                        layer.wrappedValue.textStyle?.isUnderlined.toggle()
                        edit(true)
                    }
                }
                HStack(spacing: 7) {
                    alignButtons(layer, style: style)
                    swatchRow(layer, style: style)
                    Button {
                        morePanelID = layer.wrappedValue.id
                        showAutoInfo = false
                    } label: {
                        Text("More…")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 9)
                            .frame(height: M.face)
                            .background(
                                RoundedRectangle(cornerRadius: M.faceRadius, style: .continuous)
                                    .fill(M.controlFill))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(
                        get: { morePanelID == layer.wrappedValue.id },
                        set: { if !$0 { morePanelID = nil } })) {
                        spacingPopover(layer)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// The face on show: a curated system family, or one the project
    /// imported (tagged), or the system face.
    private func fontLabel(for style: TextOverlayContent) -> (label: String, imported: Bool) {
        guard let family = style.fontFamily, !family.isEmpty else { return ("SF Pro", false) }
        if let choice = Self.fontChoices.first(where: { $0.family == family }) {
            return (choice.label, false)
        }
        if importedFonts.contains(where: { $0.family.caseInsensitiveCompare(family) == .orderedSame }) {
            return (family, true)
        }
        return (family, false)
    }

    /// The font field. A popover list rather than a `Menu`: AppKit renders
    /// a SwiftUI menu label as a plain pull-down and drops the field chrome,
    /// and the list needs a divider, an IMPORTED tag and an import row the
    /// menu could not draw.
    private func fontPicker(
        _ layer: Binding<SceneOverlay>, style: TextOverlayContent
    ) -> some View {
        let current = fontLabel(for: style)
        let id = layer.wrappedValue.id
        return Button {
            fontPickerID = id
        } label: {
            HStack(spacing: 6) {
                Text(current.label)
                    .font(previewFont(family: style.fontFamily, size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if current.imported { importedTag }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: M.field)
            .background(
                RoundedRectangle(cornerRadius: M.fieldRadius, style: .continuous)
                    .fill(M.controlFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Font: \(current.label)")
        .popover(isPresented: Binding(
            get: { fontPickerID == id },
            set: { if !$0 { fontPickerID = nil } })) {
            fontList(layer, style: style)
        }
    }

    private var importedTag: some View {
        Text("IMPORTED")
            .font(.system(size: 9, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(accent.opacity(0.1)))
    }

    /// A family shown in its own face where the device has it, else the
    /// system face — the same fallback the rasterizer applies.
    private func previewFont(family: String?, size: CGFloat) -> Font {
        guard let family, !family.isEmpty else { return .system(size: size) }
        return .custom(family, size: size)
    }

    @ViewBuilder private func fontList(_ layer: Binding<SceneOverlay>, style: TextOverlayContent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.fontChoices, id: \.label) { choice in
                fontRow(
                    choice.label, family: choice.family, imported: false,
                    on: (style.fontFamily ?? "") == (choice.family ?? "")
                ) {
                    layer.wrappedValue.textStyle?.fontFamily = choice.family
                    fontPickerID = nil
                    edit(true)
                }
            }
            if !importedFonts.isEmpty {
                popoverDivider
                ForEach(importedFonts) { font in
                    fontRow(
                        font.family, family: font.family, imported: true,
                        on: style.fontFamily?.caseInsensitiveCompare(font.family) == .orderedSame
                    ) {
                        layer.wrappedValue.textStyle?.fontFamily = font.family
                        fontPickerID = nil
                        edit(true)
                    }
                }
            }
            popoverDivider
            Button {
                fontPickerID = nil
                isImportingFont = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Import font…")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("TTF · OTF")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
        }
        .padding(6)
        .frame(width: 230)
        #if os(iOS)
        .presentationCompactAdaptation(.popover)
        #endif
    }

    private var popoverDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
    }

    private func fontRow(
        _ label: String, family: String?, imported: Bool, on: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(previewFont(family: family, size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if imported {
                    Text("IMPORTED")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(accent)
                }
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowButtonStyle())
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func faceButton(
        _ glyph: String, on: Bool, weight: Font.Weight = .regular,
        italic: Bool = false, underline: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 12.5, weight: weight))
                .italic(italic)
                .underline(underline)
                .foregroundStyle(on ? onAccent : Color.primary)
                .frame(width: M.face, height: M.face)
                .background(
                    RoundedRectangle(cornerRadius: M.faceRadius, style: .continuous)
                        .fill(on ? accent : M.controlFill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func alignButtons(
        _ layer: Binding<SceneOverlay>, style: TextOverlayContent
    ) -> some View {
        HStack(spacing: 7) {
            ForEach(OverlayTextAlignment.allCases, id: \.self) { alignment in
                let on = style.alignment == alignment
                Button {
                    layer.wrappedValue.textStyle?.alignment = alignment
                    edit(true)
                } label: {
                    Image(systemName: "text.align\(alignment.rawValue)")
                        .font(.system(size: 11))
                        .foregroundStyle(on ? onAccent : Color.primary)
                        .frame(width: M.face, height: M.face)
                        .background(
                            RoundedRectangle(cornerRadius: M.faceRadius, style: .continuous)
                                .fill(on ? accent : M.controlFill))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Align \(alignment.rawValue)")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }

    private func swatchRow(
        _ layer: Binding<SceneOverlay>, style: TextOverlayContent
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(Self.swatches, id: \.hex) { swatch in
                let on = style.colorHex.caseInsensitiveCompare(swatch.hex) == .orderedSame
                swatchButton(swatch, on: on, size: M.swatch, ringBase: LL.cardBackground) {
                    // The TYPE row's swatch is the layer's colour; a word's
                    // own colour is set from the copy field's toolbar.
                    layer.wrappedValue.textStyle?.setColor(swatch.hex, in: nil)
                    edit(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// A colour disc. Selected: a white ring inside an accent ring.
    private func swatchButton(
        _ swatch: (name: String, hex: String), on: Bool, size: CGFloat, ringBase: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(cgColor: TextOverlayRasterizer.color(fromHex: swatch.hex)))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0 : 0.12), lineWidth: 1))
                .overlay {
                    if on {
                        Circle().strokeBorder(ringBase, lineWidth: 2).padding(-2)
                        Circle().strokeBorder(accent, lineWidth: 1.5).padding(-3.5)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(swatch.name)
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: Spacing & sizing popover

    @ViewBuilder private func spacingPopover(_ layer: Binding<SceneOverlay>) -> some View {
        let value = layer.wrappedValue
        let boxed = value.mode == .box
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Spacing & sizing")
                    .font(.system(size: 14, weight: .bold))
                Text(String(value.text.prefix(22)))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            dial("Kerning", value: Binding(
                get: { layer.wrappedValue.textStyle?.kerning ?? 0 },
                set: { layer.wrappedValue.textStyle?.kerning = $0; edit(false) }),
                 range: -4...12, format: "%.1f")
            dial("Line height", value: Binding(
                get: { layer.wrappedValue.textStyle?.lineHeight ?? 1 },
                set: { layer.wrappedValue.textStyle?.lineHeight = $0; edit(false) }),
                 range: 0.8...2.2, format: "%.2f")
            dial("Paragraph", value: Binding(
                get: { layer.wrappedValue.textStyle?.paragraphSpacing ?? 0 },
                set: { layer.wrappedValue.textStyle?.paragraphSpacing = $0; edit(false) }),
                 range: 0...1.5, format: "%.2f")

            Divider()

            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { boxed && layer.wrappedValue.autoSize },
                    set: { next in
                        guard boxed else { return }
                        layer.wrappedValue.autoSize = next
                        edit(true)
                    })) {
                    Text("Auto-Size font")
                        .font(.system(size: 13.5, weight: .semibold))
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .tint(accent)
                .disabled(!boxed)
                .opacity(boxed ? 1 : 0.42)
                .fixedSize()

                Button { showAutoInfo.toggle() } label: {
                    Text("i")
                        .font(.system(size: 10, weight: .semibold, design: .serif))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(M.controlFill))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What Auto-Size does")
                Spacer(minLength: 0)
            }

            if showAutoInfo {
                Text("Auto-Size only exists inside a bounding box: the box is the constraint the type is fitted to. It grows the text to the largest size that still fits, between Min and Max, and overrides Size above. Free text has no boundary to fit, so there is nothing to solve for.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(M.controlFill))
            }

            let limitsLive = boxed && value.autoSize
            dial("Min size", value: Binding(
                get: { layer.wrappedValue.minSize },
                set: { next in
                    layer.wrappedValue.minSize = min(next, layer.wrappedValue.maxSize - 0.005)
                    edit(false)
                }), range: 0.02...0.22, format: nil, pixels: true)
                .disabled(!limitsLive)
                .opacity(limitsLive ? 1 : 0.42)
            dial("Max size", value: Binding(
                get: { layer.wrappedValue.maxSize },
                set: { next in
                    layer.wrappedValue.maxSize = max(next, layer.wrappedValue.minSize + 0.005)
                    edit(false)
                }), range: 0.02...0.22, format: nil, pixels: true)
                .disabled(!limitsLive)
                .opacity(limitsLive ? 1 : 0.42)

            Text(boxed
                ? "Auto-Size overrides Size above and solves for the largest fit inside the box."
                : "Auto-Size, Min and Max need a bounding box — switch Mode to Box to use them.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
        #if os(iOS)
        .presentationCompactAdaptation(.popover)
        #endif
    }

    /// A labelled slider with a monospaced readout — the panel's one dial
    /// shape, used by both the popover and the mask controls.
    private func dial(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>,
        format: String?, pixels: Bool = false
    ) -> some View {
        HStack(spacing: 9) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if !editing { edit(true) }
            }
            .tint(accent)
            Text(pixels
                ? "\(Int((value.wrappedValue * frameLongEdgePixels).rounded()))px"
                : String(format: format ?? "%.2f", value.wrappedValue))
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }

    // MARK: Placement

    @ViewBuilder private func placementSection(_ layer: Binding<SceneOverlay>) -> some View {
        let regions = document.placementRegions
        let options: [(placement: OverlayPlacement, label: String)] =
            [(.none, "None")] + regions
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 1) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    segmentPill(
                        option.label,
                        selected: layer.wrappedValue.placement == option.placement
                    ) {
                        layer.wrappedValue.placement = option.placement
                        edit(true)
                    }
                }
                // Not a value — the route to where regions are authored.
                segmentPill("Custom", selected: false, action: onOpenMasks)
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: M.segment / 2, style: .continuous)
                    .fill(M.controlFill))
        }
        .padding(.bottom, 12)
    }

    // MARK: Reveal in

    /// The header's readout: the band and its length, or the cut.
    private func revealInSummary(_ layer: SceneOverlay) -> String {
        let reveal = layer.effectiveAnimation.reveal
        guard reveal.style != nil else { return "Cut · appears at \(label(reveal.start))" }
        return "\(label(reveal.start)) → \(label(reveal.end)) · \(durationLabel(reveal.duration))"
    }

    /// Mutates the layer's animation (materialising one from `alwaysOn`
    /// when it had none), then reports the edit.
    private func update(
        _ layer: Binding<SceneOverlay>, commit: Bool = true,
        _ body: (inout OverlayAnimation) -> Void
    ) {
        var next = layer.wrappedValue.effectiveAnimation
        body(&next)
        layer.wrappedValue.animation = next
        edit(commit)
    }

    @ViewBuilder private func revealInSection(_ layer: Binding<SceneOverlay>) -> some View {
        let animation = layer.wrappedValue.effectiveAnimation
        let reveal = animation.reveal
        VStack(alignment: .leading, spacing: 9) {
            unitRow(reveal.unit) { unit in
                update(layer) { $0.reveal.unit = unit }
            }
            styleChips(OverlayReveal.Style.allCases, selected: reveal.style) { style in
                update(layer) { next in
                    if next.reveal.style == style {
                        // Tapping the active chip clears it: a hard cut.
                        next.reveal.style = nil
                    } else {
                        next.reveal.style = style
                        if next.reveal.duration < 0.005 {
                            // A cut has no band; a style needs one. Open it
                            // at the playhead, the moment being looked at.
                            let seeded = OverlayAnimation.seeded(at: position).reveal
                            next.reveal.start = seeded.start
                            next.reveal.end = seeded.end
                            if var exit = next.exit, exit.start < next.reveal.end {
                                exit.start = next.reveal.end
                                exit.end = max(exit.end, exit.start + 0.01)
                                next.exit = exit
                            }
                        }
                    }
                }
            }

            if reveal.style == .slide {
                fromRow(reveal.direction) { direction in
                    update(layer) { $0.reveal.direction = direction }
                }
            }

            if reveal.unit != .element {
                staggerRow(reveal.overlap, set: { value, commit in
                    update(layer, commit: commit) { $0.reveal.overlap = value }
                })
            }

            // The playhead is the precision instrument — scrub, then pin.
            HStack(spacing: 10) {
                rangeButton("Set Start", value: label(reveal.start)) {
                    update(layer) { next in
                        // Pinning a start by hand is choosing a time, so
                        // the layer stops following.
                        next.follows = nil
                        let duration = next.reveal.duration
                        next.reveal.start = min(max(position, 0), 0.98)
                        next.reveal.end = min(1, next.reveal.start + duration)
                        if var exit = next.exit, exit.start < next.reveal.end {
                            exit.start = next.reveal.end
                            exit.end = max(exit.end, exit.start + 0.01)
                            next.exit = exit
                        }
                    }
                }
                rangeButton("Set End", value: label(reveal.end)) {
                    update(layer) { next in
                        // Only the duration changes; a link is kept.
                        next.reveal.end = min(max(position, next.reveal.start + OverlayReveal.minimumDuration), 1)
                        if var exit = next.exit, exit.start < next.reveal.end {
                            exit.start = next.reveal.end
                            exit.end = max(exit.end, exit.start + 0.01)
                            next.exit = exit
                        }
                    }
                }
            }

            startsRow(layer, animation: animation)
            if animation.follows != nil {
                parentRow(layer, animation: animation)
                footnoteSmall("Offset is measured from the parent's reveal end; negative overlaps them.")
                independentPositionRow(layer, animation: animation)
            }
        }
        .padding(.bottom, 12)
    }

    private func unitRow(_ unit: OverlayReveal.Unit, set: @escaping (OverlayReveal.Unit) -> Void) -> some View {
        HStack(spacing: 1) {
            ForEach(OverlayReveal.Unit.allCases, id: \.self) { candidate in
                segmentPill(candidate.displayName, selected: candidate == unit, fill: true) {
                    guard candidate != unit else { return }
                    set(candidate)
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(M.controlFill))
    }

    /// Style chips; the active one reads as a toggle (tapping it again is a
    /// hard cut — the caller decides what "again" does).
    private func styleChips(
        _ styles: [OverlayReveal.Style], selected: OverlayReveal.Style?,
        pick: @escaping (OverlayReveal.Style) -> Void
    ) -> some View {
        FlowRow(spacing: 5) {
            ForEach(styles, id: \.self) { style in
                let on = style == selected
                Button {
                    pick(style)
                } label: {
                    Text(style.displayName)
                        .font(.system(size: M.chipFont, weight: .semibold))
                        .foregroundStyle(on ? onAccent : Color.primary)
                        .padding(.horizontal, M.chipPadding)
                        .frame(height: M.chip)
                        .background(Capsule().fill(on ? accent : M.controlFill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
                .help(on ? "Tap again for a hard cut" : style.displayName)
            }
        }
    }

    private func fromRow(_ direction: OverlayAnimation.Direction, set: @escaping (OverlayAnimation.Direction) -> Void) -> some View {
        HStack(spacing: 8) {
            Text("From")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            segmentRow(
                OverlayAnimation.Direction.allCases.map(\.displayName),
                selectedIndex: OverlayAnimation.Direction.allCases.firstIndex(of: direction) ?? 1
            ) { index in
                set(OverlayAnimation.Direction.allCases[index])
            }
        }
    }

    private func staggerRow(_ overlap: Double, set: @escaping (Double, Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            Text("Stagger")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Slider(
                value: Binding(get: { overlap }, set: { set($0, false) }),
                in: 0...1
            ) { editing in
                if !editing { set(overlap, true) }
            }
            .tint(accent)
            Text(overlap < 0.2 ? "one at a time" : overlap > 0.85 ? "almost together" : "overlapping")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stagger")
    }

    // MARK: Sequencing

    /// The layers this one may follow — everything but itself and its own
    /// descendants (a parent cannot follow one of its children).
    private func parentCandidates(for id: UUID) -> [SceneOverlay] {
        let excluded = document.descendants(of: id).union([id])
        return document.overlays.filter { !excluded.contains($0.id) }
    }

    private func startsRow(_ layer: Binding<SceneOverlay>, animation: OverlayAnimation) -> some View {
        let id = layer.wrappedValue.id
        let after = animation.follows != nil
        let candidates = parentCandidates(for: id)
        return HStack(spacing: 8) {
            Text("Starts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            HStack(spacing: 1) {
                segmentPill("At time", selected: !after) {
                    guard after else { return }
                    update(layer) { $0.follows = nil }
                }
                segmentPill("After layer", selected: after) {
                    guard !after, let first = candidates.first else { return }
                    link(layer, to: first)
                }
                .disabled(!after && candidates.isEmpty)
                .opacity(!after && candidates.isEmpty ? 0.45 : 1)
            }
            .padding(2)
            .background(Capsule().fill(M.controlFill))
            Spacer(minLength: 0)
        }
    }

    private func link(_ layer: Binding<SceneOverlay>, to parent: SceneOverlay) {
        update(layer) { next in
            let gap = next.follows?.gap ?? 0
            next.follows = OverlayFollow(layerID: parent.id, gap: gap)
        }
        onToast("Linked — starts after “\(parent.displayName)”")
    }

    /// The parent picker and the offset stepper.
    private func parentRow(_ layer: Binding<SceneOverlay>, animation: OverlayAnimation) -> some View {
        let id = layer.wrappedValue.id
        let parent = animation.follows.flatMap { follow in
            document.overlays.first { $0.id == follow.layerID }
        }
        let gap = animation.follows?.gap ?? 0
        let step = frameStep > 0 ? frameStep : 0.005
        return HStack(spacing: 6) {
            Button {
                parentPickerID = id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(accent)
                    Text(parent?.displayName ?? "—")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 9)
                .frame(height: M.field)
                .background(
                    RoundedRectangle(cornerRadius: M.fieldRadius, style: .continuous)
                        .fill(M.controlFill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Starts after \(parent?.displayName ?? "no layer")")
            .popover(isPresented: Binding(
                get: { parentPickerID == id },
                set: { if !$0 { parentPickerID = nil } })) {
                parentList(layer, current: parent?.id)
            }

            HStack(spacing: 0) {
                stepButton("minus") {
                    update(layer) { next in
                        let gap = next.follows?.gap ?? 0
                        next.follows?.gap = max(-0.1, gap - step)
                    }
                }
                Text((gap >= 0 ? "+" : "−") + durationLabel(abs(gap)))
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 44)
                stepButton("plus") {
                    update(layer) { next in
                        let gap = next.follows?.gap ?? 0
                        next.follows?.gap = min(0.3, gap + step)
                    }
                }
            }
            .frame(height: M.field)
            .background(
                RoundedRectangle(cornerRadius: M.fieldRadius, style: .continuous)
                    .fill(M.controlFill))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Offset")
        }
    }

    /// "Independent Position" — the one thing about a link that is about
    /// PLACE rather than time. Off (the default) a follower travels with its
    /// parent across the picture; on, it keeps the spot it was put in, which
    /// is what a byline in a corner or a URL along the bottom wants while
    /// still waiting its turn in the story.
    private func independentPositionRow(
        _ layer: Binding<SceneOverlay>, animation: OverlayAnimation
    ) -> some View {
        let on = animation.follows?.independentPosition ?? false
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                update(layer) { next in next.follows?.independentPosition.toggle() }
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(on ? accent : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(on ? accent : Color.primary.opacity(0.3), lineWidth: 1))
                        .overlay {
                            if on {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(onAccent)
                            }
                        }
                        .frame(width: 16, height: 16)
                    Text("Independent Position")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Independent position")
            .accessibilityValue(on ? "on" : "off")
            footnoteSmall(
                "Off: moves with its parent on the picture. On: stays where you put it; only the timing follows.")
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 24, height: M.field)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Later by one frame" : "Earlier by one frame")
    }

    @ViewBuilder private func parentList(_ layer: Binding<SceneOverlay>, current: UUID?) -> some View {
        let candidates = parentCandidates(for: layer.wrappedValue.id)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(candidates) { candidate in
                let hasLabel = !candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button {
                    parentPickerID = nil
                    link(layer, to: candidate)
                } label: {
                    HStack(spacing: 8) {
                        (Text(candidate.displayName)
                            + (hasLabel ? Text(" · \(candidate.listTitle)").foregroundColor(.primary.opacity(0.5)) : Text("")))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        if candidate.id == current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PopoverRowButtonStyle())
            }
        }
        .padding(6)
        .frame(width: 200)
        #if os(iOS)
        .presentationCompactAdaptation(.popover)
        #endif
    }

    // MARK: Reveal out

    /// The header toggle. On with no prior exit seeds one a while after the
    /// reveal ends; off drops it.
    private func setExit(_ layer: Binding<SceneOverlay>, on: Bool) {
        update(layer) { next in
            if on {
                if next.exit == nil || next.exit!.start < next.reveal.end {
                    next.exit = OverlayAnimation.seededExit(after: next.reveal)
                }
            } else {
                next.exit = nil
            }
        }
    }

    @ViewBuilder private func revealOutSection(_ layer: Binding<SceneOverlay>) -> some View {
        let animation = layer.wrappedValue.effectiveAnimation
        VStack(alignment: .leading, spacing: 9) {
            if let exit = animation.exit {
                unitRow(exit.unit) { unit in
                    update(layer) { $0.exit?.unit = unit }
                }
                styleChips(OverlayReveal.Style.exitStyles, selected: exit.style) { style in
                    update(layer) { next in
                        let current = next.exit?.style
                        next.exit?.style = current == style ? nil : style
                    }
                }
                if exit.style == .slide {
                    fromRow(exit.direction) { direction in
                        update(layer) { $0.exit?.direction = direction }
                    }
                }
                if exit.unit != .element {
                    staggerRow(exit.overlap, set: { value, commit in
                        update(layer, commit: commit) { $0.exit?.overlap = value }
                    })
                }
                HStack(spacing: 10) {
                    rangeButton("Set Out Start", value: revealOutSummary(exit)) {
                        update(layer) { next in
                            var exit = next.exit ?? OverlayAnimation.seededExit(after: next.reveal)
                            exit.start = min(max(position, next.reveal.end), 0.99)
                            exit.end = max(exit.end, exit.start + OverlayReveal.minimumDuration)
                            next.exit = exit
                        }
                    }
                    rangeButton("Set Out End", value: durationLabel(exit.duration)) {
                        update(layer) { next in
                            var exit = next.exit ?? OverlayAnimation.seededExit(after: next.reveal)
                            exit.end = min(max(position, exit.start + OverlayReveal.minimumDuration), 1)
                            next.exit = exit
                        }
                    }
                }
                footnoteSmall("Tap the active style again for a hard cut. Off: the text holds on screen until the end of the shoot.")
            } else {
                footnoteSmall("Off: the text holds on screen until the end of the shoot.")
            }
        }
        .padding(.bottom, 12)
    }

    private func revealOutSummary(_ exit: OverlayReveal) -> String {
        guard exit.style != nil else { return "Cut at \(label(exit.end))" }
        return "\(label(exit.start)) → \(label(exit.end))"
    }

    // MARK: ID

    /// One row: the layer's own name. Blank by default; when set it leads
    /// the row title and the After-layer picker.
    private func idRow(_ layer: Binding<SceneOverlay>) -> some View {
        HStack(spacing: 8) {
            Text("ID")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            TextField(
                "e.g. Intro top · Byline · Main message",
                text: Binding(
                    get: { layer.wrappedValue.label },
                    set: { next in
                        layer.wrappedValue.label = next
                        edit(false)
                    }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .frame(height: M.field)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LL.cardBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
                .onSubmit { edit(true) }
                .accessibilityLabel("Layer ID")
        }
        .padding(.bottom, 12)
    }

    private func rangeButton(
        _ title: String, value: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(value)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: M.setButton)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .background(M.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Remove

    private func removeButton(_ id: UUID) -> some View {
        Button {
            // Children keep their (resolved) times and stop following.
            document.removeLayer(id)
            if selectedID == id { selectedID = document.overlays.first?.id }
            expanded.remove(id)
            openSections = openSections.filter { $0.layer != id }
            edit(true)
        } label: {
            Label("Remove Text", systemImage: "trash")
                .font(.system(size: 13.5, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: M.remove)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.red.opacity(0.08)))
    }

    // MARK: - Bits

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    private func footnoteSmall(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A segment of a capsule track: accent text at rest, accent fill when
    /// selected. `fill` stretches it to share the track evenly.
    private func segmentPill(
        _ title: String, selected: Bool, fill: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: M.chipFont, weight: .semibold))
                .foregroundStyle(selected ? onAccent : accent)
                .padding(.horizontal, 10)
                .frame(maxWidth: fill ? .infinity : nil)
                .frame(height: M.segment - 4)
                .background(Capsule().fill(selected ? accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The Ken Burns capsule-segment idiom, generalized.
    private func segmentRow(
        _ titles: [String], selectedIndex: Int, onSelect: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                segmentPill(title, selected: index == selectedIndex) {
                    guard index != selectedIndex else { return }
                    onSelect(index)
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(M.controlFill))
    }
}

/// Which copy field is being edited, and which of its characters the run
/// toolbar styles: a selection, or the word under the caret. `range` nil =
/// the whole layer.
struct OverlayRunTarget: Equatable {
    var layer: UUID
    var range: Range<Int>?
}

/// B · U · six swatches, acting on `range` of the layer's copy — or, with
/// none, on the whole layer. The Mac draws it in an ink bar under the copy
/// field; iOS pins it above the keyboard.
struct OverlayRunToolbarControls: View {
    @Binding var layer: SceneOverlay
    let range: Range<Int>?
    let accent: Color
    let onAccent: Color
    var compact: Bool = false
    let onEdited: () -> Void

    private static let swatches: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"), ("Ink", "#1C1C1E"), ("Accent", "#C36A00"),
        ("Amber", "#FFB340"), ("Lemon", "#F3E37C"), ("Charcoal", "#3A3A3C"),
    ]

    private var idle: Color { Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255) }

    var body: some View {
        let style = layer.textStyle
        let run = range.flatMap { style?.run(at: $0.lowerBound) }
        let boldOn = run.map { style?.resolvedBold($0) ?? false } ?? (style?.isBold ?? false)
        let underlineOn = run.map { style?.resolvedUnderline($0) ?? false } ?? (style?.isUnderlined ?? false)
        let color = run.map { style?.resolvedColorHex($0) ?? "" } ?? (style?.colorHex ?? "")
        let size = OverlayPanelMetrics.toolbarButton
        HStack(spacing: compact ? 8 : 6) {
            Button {
                layer.textStyle?.toggleBold(in: range)
                onEdited()
            } label: {
                Text("B")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(boldOn ? onAccent : Color.white)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(boldOn ? accent : idle))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(range == nil ? "Bold layer" : "Bold word")
            Button {
                layer.textStyle?.toggleUnderline(in: range)
                onEdited()
            } label: {
                Text("U")
                    .font(.system(size: 12))
                    .underline()
                    .foregroundStyle(underlineOn ? onAccent : Color.white)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(underlineOn ? accent : idle))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(range == nil ? "Underline layer" : "Underline word")
            HStack(spacing: 5) {
                ForEach(Self.swatches, id: \.hex) { swatch in
                    let on = color.caseInsensitiveCompare(swatch.hex) == .orderedSame
                    Button {
                        layer.textStyle?.setColor(swatch.hex, in: range)
                        onEdited()
                    } label: {
                        Circle()
                            .fill(Color(cgColor: TextOverlayRasterizer.color(fromHex: swatch.hex)))
                            .frame(width: OverlayPanelMetrics.toolbarSwatch,
                                   height: OverlayPanelMetrics.toolbarSwatch)
                            .overlay(Circle().strokeBorder(Color.white.opacity(on ? 0 : 0.12), lineWidth: 1))
                            .overlay {
                                if on {
                                    Circle().strokeBorder(Color.white, lineWidth: 2).padding(-2)
                                    Circle().strokeBorder(accent, lineWidth: 1.5).padding(-3.5)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
        }
    }
}

/// The 30×16 switch in the REVEAL OUT header — drawn rather than the
/// platform switch, which is a 51pt control on iOS and a checkbox on the
/// Mac; neither fits a section header.
struct MiniToggle: View {
    @Binding var isOn: Bool
    var accent: Color = LL.accent

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? accent : LL.controlFill)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .padding(1)
            }
            .frame(width: 30, height: 16)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reveal out")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A popover list row: the design's hover fill, no button chrome.
struct PopoverRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed || hovering
                          ? OverlayPanelMetrics.controlFill : Color.clear))
            .onHover { hovering = $0 }
    }
}

/// A wrapping HStack. The placement row's pill count grows with the
/// project's custom masks, and a fixed row would push "Custom" off the rail.
struct FlowRow: Layout {
    var spacing: CGFloat = 1
    /// Vertical gap between wrapped rows. Defaults to `spacing`, so the
    /// placement pills — which have always used one number for both — are
    /// unchanged; the mask strip wants a tighter gap between lines than
    /// between tiles.
    var lineSpacing: CGFloat?

    private var rowGap: CGFloat { lineSpacing ?? spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + rowGap * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let rows = layout(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowGap
        }
    }

    private struct Row {
        var range: Range<Int>
        var width: CGFloat
        var height: CGFloat
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var start = 0
        var x: CGFloat = 0
        var height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = x == 0 ? size.width : x + spacing + size.width
            if next > width, index > start {
                rows.append(Row(range: start..<index, width: x, height: height))
                start = index
                x = size.width
                height = size.height
            } else {
                x = next
                height = max(height, size.height)
            }
        }
        if start < subviews.count {
            rows.append(Row(range: start..<subviews.count, width: x, height: height))
        }
        return rows
    }
}

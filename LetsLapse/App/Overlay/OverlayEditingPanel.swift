import SwiftUI

/// The Text tab: a list of text layers, front-to-back, each opening into its
/// own text, type, placement and animation controls.
///
/// Owns no document state: the editor holds the overlay document and
/// everything here goes back through `onEdited` — `commit: true` for finished
/// gestures (persist + render), `false` for live motion (render only).
/// Disclosure and selection ARE held here, because which card is open
/// describes the editor, not the piece.
struct OverlayEditingPanel: View {
    @Binding var document: OverlayDocument
    /// The layer the preview draws chrome around. Shared with the viewer.
    @Binding var selectedID: UUID?
    /// True when this capture has length — the only case reveal animation
    /// can mean anything.
    let hasTimeline: Bool
    /// The playhead, for Set Start / Set End.
    let position: Double
    /// Formats a position the way the strip does, so "Start" and the
    /// timeline bubble speak the same clock.
    let label: (Double) -> String
    let accent: Color
    /// The source frame's long edge in pixels, so the size readout is a real
    /// number about the delivered file rather than a preview-relative one.
    let frameLongEdgePixels: Double
    /// Frame aspect (w ÷ h), for resolving auto-size the same way the
    /// rasterizer will.
    let frameAspect: Double
    let onEdited: (_ commit: Bool) -> Void
    /// "Custom" on the placement row is a route to the Masks tab, not a value.
    let onOpenMasks: () -> Void

    /// Which cards and sections are open. Keyed by layer, so opening one
    /// layer's TYPE section does not open every layer's.
    @State private var expanded: Set<UUID> = []
    @State private var openSections: Set<SectionKey> = []
    /// Layers whose disclosure defaults have been applied. Without this a
    /// layer seeded from the sidecar would open with every section shut,
    /// and the text — the thing you came to edit — would be two taps away.
    @State private var seededDefaults: Set<UUID> = []
    @State private var morePanelID: UUID?
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
        case text, type, placement, animation

        var title: String {
            switch self {
            case .text: return "TEXT & SIZE"
            case .type: return "TYPE"
            case .placement: return "INTELLIGENT PLACEMENT"
            case .animation: return "ANIMATION"
            }
        }
    }

    /// The faces the type picker offers. A curated list, not every installed
    /// family: the point is a handful of good, universally present choices.
    /// nil family = the system face.
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
        ("Sky", "#8FA3B8"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(spacing: 10) {
                ForEach($document.overlays) { $layer in
                    layerCard($layer)
                }
            }
            .task(id: document.overlays.map(\.id)) { seedSectionDefaults() }
            addButton
            footnote(
                "Drag the text on the preview to place it. Where it rests is where every animation ends. Drag a layer by its grip to reorder — the top layer sits in front.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Text Layers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(document.overlays.count) \(document.overlays.count == 1 ? "layer" : "layers")")
                .font(.system(size: 11))
                .monospaced()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private var addButton: some View {
        Button {
            var layer = SceneOverlay(content: .text(.init(string: "Your text")))
            layer.size = 0.08
            layer.centerY = 0.62
            // New layers go to the FRONT of the list, which is the front of
            // the stack: the thing just added is the thing being worked on.
            document.overlays.insert(layer, at: 0)
            selectedID = layer.id
            expanded.insert(layer.id)
            openSections.insert(SectionKey(layer: layer.id, section: .text))
            openSections.insert(SectionKey(layer: layer.id, section: .type))
            onEdited(true)
        } label: {
            Label("Add Text", systemImage: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Text(value.listTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(value.isVisible ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            animationGlyph(value)
            onionToggle(layer)
            expandChevron(id)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 38)
        .background(isSelectedBackground(id))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = id }
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

    /// A row-height drag: each 44 pt of travel moves the layer one seat.
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
                onEdited(false)
            }
            .onEnded { _ in
                draggingID = nil
                onEdited(true)
            }
    }

    private func visibilityToggle(_ layer: Binding<SceneOverlay>) -> some View {
        let visible = layer.wrappedValue.isVisible
        return Button {
            layer.wrappedValue.isVisible.toggle()
            onEdited(true)
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
        let on = layer.animation != nil
        return Image(systemName: on ? "wand.and.stars" : "wand.and.stars.inverse")
            .font(.system(size: 12))
            .foregroundStyle(on ? accent : Color.secondary.opacity(0.4))
            .frame(width: 18, height: 18)
            .help(on
                ? "Animation: \(layer.animation?.style.displayName ?? "")"
                : "Animation: none")
            .accessibilityHidden(true)
    }

    /// Onion skin only means something against an animation: with no reveal
    /// the text is always drawn, so there is nothing to see through.
    private func onionToggle(_ layer: Binding<SceneOverlay>) -> some View {
        let value = layer.wrappedValue
        let disabled = value.animation == nil
        let on = value.onionSkin && !disabled
        return Button {
            guard !disabled else { return }
            layer.wrappedValue.onionSkin.toggle()
            onEdited(true)
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
            ? "Onion skin needs an animation — with no reveal the text is always drawn"
            : "Onion skin: draw the text at full opacity, ignoring the animation")
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
                        .fill(open ? LL.screenBackground : .clear))
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
            if isOpen(.text, id) { textAndSizeSection(layer) }
            divider
            sectionHeader(.type, layer: id)
            if isOpen(.type, id) { typeSection(layer) }
            divider
            sectionHeader(.placement, layer: id)
            if isOpen(.placement, id) { placementSection(layer) }
            if hasTimeline {
                divider
                sectionHeader(.animation, layer: id)
                if isOpen(.animation, id) { animationSection(layer) }
            }
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
        let key = SectionKey(layer: id, section: section)
        let open = openSections.contains(key)
        return Button {
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
                Spacer()
            }
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Text & size

    @ViewBuilder private func textAndSizeSection(_ layer: Binding<SceneOverlay>) -> some View {
        let value = layer.wrappedValue
        VStack(alignment: .leading, spacing: 9) {
            TextField(
                "Text — press Return for a new line",
                text: Binding(
                    get: { layer.wrappedValue.text },
                    set: { next in
                        layer.wrappedValue.text = next
                        onEdited(false)
                    }),
                axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .font(.system(size: 14))
                .focused($focusedLayer, equals: value.id)
                #if os(iOS)
                // The soft keyboard needs an explicit exit: without one the
                // only way out was leaving the tab (found on device
                // 2026-08-31). Return inserts a newline here — the field is
                // multi-line now — so the toolbar is the exit, along with the
                // editor resigning focus when a drag or scrub starts.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            focusedLayer = nil
                            onEdited(true)
                        }
                        .font(.system(size: 15, weight: .semibold))
                    }
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
                    onEdited(true)
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
                        onEdited(false)
                    }),
                style: .inline,
                accent: accent,
                onEditing: { editing in
                    if !editing { onEdited(true) }
                })
        }
        .padding(.bottom, 12)
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
                        onEdited(false)
                    }),
                in: 0.02...0.22
            ) { editing in
                if !editing { onEdited(true) }
            }
            .tint(accent)
            .disabled(auto)
            .opacity(auto ? 0.45 : 1)
            Text("\(Int((resolved * frameLongEdgePixels).rounded())) px")
                .font(.system(size: 12, weight: .semibold))
                .monospaced()
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
                    faceButtons(layer, style: style)
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
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LL.screenBackground))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(
                        get: { morePanelID == layer.wrappedValue.id },
                        set: { if !$0 { morePanelID = nil } })) {
                        spacingPopover(layer)
                    }
                }
                Text(typeSummary(layer.wrappedValue, style: style))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)
        }
    }

    private func typeSummary(_ layer: SceneOverlay, style: TextOverlayContent) -> String {
        let family = Self.fontChoices
            .first { $0.family == style.fontFamily }?.label ?? "SF Pro"
        var parts = [family, style.isBold ? "Bold" : "Regular"]
        if style.isItalic { parts[1] += " Italic" }
        parts.append(String(format: "kern %.1f", style.kerning))
        parts.append(String(format: "line %.2f", style.lineHeight))
        if layer.mode == .box && layer.autoSize { parts.append("auto-size on") }
        return parts.joined(separator: " · ")
    }

    private func fontPicker(
        _ layer: Binding<SceneOverlay>, style: TextOverlayContent
    ) -> some View {
        Picker("Font", selection: Binding(
            get: { style.fontFamily ?? "" },
            set: { next in
                layer.wrappedValue.textStyle?.fontFamily = next.isEmpty ? nil : next
                onEdited(true)
            })) {
            ForEach(Self.fontChoices, id: \.label) { choice in
                Text(choice.label).tag(choice.family ?? "")
            }
        }
        .labelsHidden()
        .font(.system(size: 12.5))
        .frame(maxWidth: .infinity)
    }

    private func faceButtons(
        _ layer: Binding<SceneOverlay>, style: TextOverlayContent
    ) -> some View {
        HStack(spacing: 1) {
            faceButton("B", on: style.isBold, weight: .bold) {
                layer.wrappedValue.textStyle?.isBold.toggle()
                onEdited(true)
            }
            faceButton("I", on: style.isItalic, italic: true) {
                layer.wrappedValue.textStyle?.isItalic.toggle()
                onEdited(true)
            }
            faceButton("U", on: style.isUnderlined, underline: true) {
                layer.wrappedValue.textStyle?.isUnderlined.toggle()
                onEdited(true)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LL.screenBackground))
    }

    private func faceButton(
        _ glyph: String, on: Bool, weight: Font.Weight = .regular,
        italic: Bool = false, underline: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 12.5, weight: weight, design: .serif))
                .italic(italic)
                .underline(underline)
                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? accent : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func alignButtons(
        _ layer: Binding<SceneOverlay>, style: TextOverlayContent
    ) -> some View {
        HStack(spacing: 1) {
            ForEach(OverlayTextAlignment.allCases, id: \.self) { alignment in
                let on = style.alignment == alignment
                Button {
                    layer.wrappedValue.textStyle?.alignment = alignment
                    onEdited(true)
                } label: {
                    Image(systemName: "text.align\(alignment.rawValue)")
                        .font(.system(size: 11))
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(on ? accent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Align \(alignment.rawValue)")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LL.screenBackground))
    }

    private func swatchRow(
        _ layer: Binding<SceneOverlay>, style: TextOverlayContent
    ) -> some View {
        HStack(spacing: 5) {
            ForEach(Self.swatches, id: \.hex) { swatch in
                let on = style.colorHex.caseInsensitiveCompare(swatch.hex) == .orderedSame
                Button {
                    layer.wrappedValue.textStyle?.colorHex = swatch.hex
                    onEdited(true)
                } label: {
                    Circle()
                        .fill(Color(cgColor: TextOverlayRasterizer.color(fromHex: swatch.hex)))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(
                            on ? accent : Color.primary.opacity(0.18),
                            lineWidth: on ? 2 : 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                set: { layer.wrappedValue.textStyle?.kerning = $0; onEdited(false) }),
                 range: -4...12, format: "%.1f")
            dial("Line height", value: Binding(
                get: { layer.wrappedValue.textStyle?.lineHeight ?? 1 },
                set: { layer.wrappedValue.textStyle?.lineHeight = $0; onEdited(false) }),
                 range: 0.8...2.2, format: "%.2f")
            dial("Paragraph", value: Binding(
                get: { layer.wrappedValue.textStyle?.paragraphSpacing ?? 0 },
                set: { layer.wrappedValue.textStyle?.paragraphSpacing = $0; onEdited(false) }),
                 range: 0...1.5, format: "%.2f")

            Divider()

            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { boxed && layer.wrappedValue.autoSize },
                    set: { next in
                        guard boxed else { return }
                        layer.wrappedValue.autoSize = next
                        onEdited(true)
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
                        .background(Circle().fill(LL.screenBackground))
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
                            .fill(LL.screenBackground))
            }

            let limitsLive = boxed && value.autoSize
            dial("Min size", value: Binding(
                get: { layer.wrappedValue.minSize },
                set: { next in
                    layer.wrappedValue.minSize = min(next, layer.wrappedValue.maxSize - 0.005)
                    onEdited(false)
                }), range: 0.02...0.22, format: nil, pixels: true)
                .disabled(!limitsLive)
                .opacity(limitsLive ? 1 : 0.42)
            dial("Max size", value: Binding(
                get: { layer.wrappedValue.maxSize },
                set: { next in
                    layer.wrappedValue.maxSize = max(next, layer.wrappedValue.minSize + 0.005)
                    onEdited(false)
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
                if !editing { onEdited(true) }
            }
            .tint(accent)
            Text(pixels
                ? "\(Int((value.wrappedValue * frameLongEdgePixels).rounded()))px"
                : String(format: format ?? "%.2f", value.wrappedValue))
                .font(.system(size: 11.5, weight: .semibold))
                .monospaced()
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
                    pill(
                        option.label,
                        selected: layer.wrappedValue.placement == option.placement
                    ) {
                        layer.wrappedValue.placement = option.placement
                        onEdited(true)
                    }
                }
                // Not a value — the route to where regions are authored.
                pill("Custom", selected: false, action: onOpenMasks)
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LL.screenBackground))
        }
        .padding(.bottom, 12)
    }

    // MARK: Animation

    @ViewBuilder private func animationSection(_ layer: Binding<SceneOverlay>) -> some View {
        let value = layer.wrappedValue
        let animation = value.animation
        VStack(alignment: .leading, spacing: 9) {
            segmentRow(
                ["None", "Fade", "Slide"],
                selectedIndex: animation == nil ? 0
                    : (animation?.style == .characterFade ? 1 : 2)
            ) { index in
                switch index {
                case 0:
                    layer.wrappedValue.animation = nil
                    // Onion skin describes an animation; with none there is
                    // nothing for it to see past.
                    layer.wrappedValue.onionSkin = false
                case 1:
                    var next = layer.wrappedValue.animation ?? defaultAnimation()
                    next.style = .characterFade
                    layer.wrappedValue.animation = next
                default:
                    var next = layer.wrappedValue.animation ?? defaultAnimation()
                    next.style = .characterSlide
                    layer.wrappedValue.animation = next
                }
                onEdited(true)
            }

            if let animation {
                if animation.style == .characterSlide {
                    HStack(spacing: 8) {
                        Text("From")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        segmentRow(
                            OverlayAnimation.Direction.allCases.map(\.displayName),
                            selectedIndex: OverlayAnimation.Direction.allCases
                                .firstIndex(of: animation.direction) ?? 1
                        ) { index in
                            layer.wrappedValue.animation?.direction =
                                OverlayAnimation.Direction.allCases[index]
                            onEdited(true)
                        }
                    }
                }

                // The playhead is the precision instrument — scrub, then pin.
                HStack(spacing: 10) {
                    rangeButton("Set Start", value: label(animation.start)) {
                        var next = animation
                        next.start = min(position, next.end - 0.02)
                        layer.wrappedValue.animation = next
                        onEdited(true)
                    }
                    rangeButton("Set End", value: label(animation.end)) {
                        var next = animation
                        next.end = max(position, next.start + 0.02)
                        layer.wrappedValue.animation = next
                        onEdited(true)
                    }
                }
                footnote("The reveal runs across this span of the shoot and always finishes exactly where the text rests.")
            }
        }
        .padding(.bottom, 12)
    }

    private func defaultAnimation() -> OverlayAnimation {
        // Open the band at the playhead's neighborhood rather than 0…25% of
        // a two-hour shoot: the user is looking at the moment they care
        // about.
        var animation = OverlayAnimation()
        animation.start = min(max(position, 0), 0.9)
        animation.end = min(animation.start + 0.1, 1)
        return animation
    }

    private func rangeButton(
        _ title: String, value: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(value)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .background(LL.screenBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Remove

    private func removeButton(_ id: UUID) -> some View {
        Button {
            document.overlays.removeAll { $0.id == id }
            if selectedID == id { selectedID = document.overlays.first?.id }
            expanded.remove(id)
            openSections = openSections.filter { $0.layer != id }
            onEdited(true)
        } label: {
            Label("Remove Text", systemImage: "trash")
                .font(.system(size: 13.5, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
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

    private func pill(
        _ title: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(selected ? Color.white : accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
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
                pill(title, selected: index == selectedIndex) {
                    guard index != selectedIndex else { return }
                    onSelect(index)
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(LL.screenBackground))
    }
}

/// A wrapping HStack. The placement row's pill count grows with the
/// project's custom masks, and a fixed row would push "Custom" off the rail.
struct FlowRow: Layout {
    var spacing: CGFloat = 1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
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
            y += row.height + spacing
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

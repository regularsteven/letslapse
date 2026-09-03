import SwiftUI
import LetsLapseKit

// Interval ladders — the list, the editor (ribbon header + list, design
// 2c-ii) and the rung screen (the five levers). Plain lists throughout, which
// is what makes iPhone and iPad one build. Design: Claude Design handoff
// "Light Ladder", Turn 2 (2b, 2c); `docs/light-ladder.md` §6.3–6.5.

enum LadderRoute: Hashable {
    case editor(UUID)
    case rung(ladder: UUID, rung: UUID)
}

// MARK: - The list

/// Reached from the ladder chip's Manage and from the Create tab's row. The
/// built-in is pinned, badged and Duplicate-only. Owns its navigation, so it
/// presents the same way from both doors.
struct LightLaddersView: View {
    @ObservedObject var store: LightLadderStore
    /// The armed ladder — nil for the built-in.
    @Binding var selectedID: UUID?
    @State private var path: [LadderRoute] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: LadderRoute.editor(LightLadder.builtInID)) {
                        LadderRow(ladder: .builtIn, isSelected: isSelected(.builtIn), isBuiltIn: true)
                    }
                } header: {
                    Text("Built in")
                } footer: {
                    Text("Open to read it or duplicate it. The built-in is never edited in place, so a shoot from six months ago still means what it meant.")
                }

                Section {
                    ForEach(store.userLadders) { ladder in
                        NavigationLink(value: LadderRoute.editor(ladder.id)) {
                            LadderRow(ladder: ladder, isSelected: isSelected(ladder), isBuiltIn: false)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) where index < store.userLadders.count {
                            let id = store.userLadders[index].id
                            if selectedID == id { selectedID = nil }
                            store.delete(id: id)
                        }
                    }
                    Button {
                        let ladder = store.createNew()
                        path.append(.editor(ladder.id))
                    } label: {
                        Label("New ladder", systemImage: "plus")
                            .foregroundStyle(LL.accent)
                    }
                } header: {
                    Text("Your ladders")
                } footer: {
                    Text("Ladders are portable: a rung stores ISO as min, max, auto or a value, resolved for whichever device and lens arms it.")
                }
            }
            .navigationTitle("Interval ladders")
            .navigationDestination(for: LadderRoute.self) { route in
                switch route {
                case .editor(let id):
                    LightLadderEditorView(store: store, ladderID: id, selectedID: $selectedID, path: $path)
                case .rung(let ladderID, let rungID):
                    LightRungView(store: store, ladderID: ladderID, rungID: rungID)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func isSelected(_ ladder: LightLadder) -> Bool {
        store.resolve(id: selectedID).id == ladder.id
    }
}

/// One ladder. The handoff draws a BUILT IN pill in the trailing slot; on a
/// 393 pt phone that pill plus the check plus the chevron left the built-in's
/// own name truncated to "Bright & Fast, Dar…", so the badge is the
/// subtitle's first word instead — the same form the picker sheet uses.
private struct LadderRow: View {
    let ladder: LightLadder
    let isSelected: Bool
    let isBuiltIn: Bool

    var body: some View {
        HStack(spacing: 12) {
            LadderSwatch(ladder: ladder)
            VStack(alignment: .leading, spacing: 2) {
                Text(ladder.name)
                    .font(.system(size: 16))
                    .lineLimit(1)
                Text(isBuiltIn ? "Built in · \(ladder.thresholdSummary)" : ladder.thresholdSummary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LL.accent)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - The editor

/// Ribbon header + list: the whole ladder in 60 pt, then the rungs
/// brightest first, then the Boundaries. Every edit writes through to the
/// store — the file is tiny and atomic — so a rung screen pushed from here
/// and the ribbon always agree. The built-in is read-only and Duplicate-only.
struct LightLadderEditorView: View {
    @ObservedObject var store: LightLadderStore
    let ladderID: UUID
    @Binding var selectedID: UUID?
    @Binding var path: [LadderRoute]
    /// The Tweaks panel's "Always visible": EV-forward instead of name-forward.
    @AppStorage("letslapse.ladder.evAlwaysVisible") private var evAlwaysVisible = false
    @State private var selectedRungID: UUID?
    @State private var name = ""
    @State private var confirmingDelete = false

    private var ladder: LightLadder { store.ladder(id: ladderID) ?? .builtIn }
    private var isBuiltIn: Bool { ladderID == LightLadder.builtInID }
    private var format: HolyGrailRampEngine.HardwareLimits { store.lastKnownFormat.limits }
    private var isArmed: Bool { store.resolve(id: selectedID).id == ladderID }

    var body: some View {
        List {
            Section {
                if isBuiltIn {
                    Text(ladder.name)
                        .font(.system(size: 16))
                } else {
                    TextField("Name", text: $name)
                        .font(.system(size: 16))
                        .onSubmit { store.rename(id: ladderID, to: name) }
                        .onChange(of: name) { value in
                            if value != ladder.name { store.rename(id: ladderID, to: value) }
                        }
                }
                if ladder.clonedFromID == LightLadder.builtInID {
                    Text("cloned from the built-in")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else if isBuiltIn {
                    Text("always present · cloneable · never editable in place")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LadderRibbon(
                    ladder: ladder,
                    selectedRungID: selectedRungID,
                    editable: !isBuiltIn,
                    onSelect: { id in
                        selectedRungID = selectedRungID == id ? nil : id
                    },
                    onMoveThreshold: moveThreshold)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                Text(isBuiltIn
                     ? "Tap a band to reveal its rung's threshold."
                     : "Drag a divider to move a threshold. Tap a band to reveal its rung's threshold.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Array(ladder.rungs.enumerated()), id: \.element.id) { index, rung in
                    Button {
                        path.append(.rung(ladder: ladderID, rung: rung.id))
                    } label: {
                        RungRow(
                            rung: rung, index: index, count: ladder.rungs.count,
                            threshold: (evAlwaysVisible || selectedRungID == rung.id)
                                ? thresholdText(at: index) : nil,
                            isSelected: selectedRungID == rung.id,
                            note: index > 0
                                ? LightLadderAdvice.boundaryStatement(above: index, in: ladder, format: format)
                                : nil)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selectedRungID == rung.id ? LL.amber.opacity(0.10) : nil)
                }
                .onDelete(perform: isBuiltIn ? nil : deleteRungs)
                if !isBuiltIn {
                    Button {
                        addRung()
                    } label: {
                        Label("Add a rung", systemImage: "plus")
                            .foregroundStyle(LL.accent)
                    }
                }
            } header: {
                Text("Rungs · brightest first")
            }

            Section {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Switching band")
                            .font(.system(size: 16))
                        Text("A rung holds until scene EV passes its threshold by this much, over 3 smoothed windows.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("±\(LightLadderFormat.ev(LightLadderSelector.switchingBandEV))")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Never mid-window")
                            .font(.system(size: 16))
                        Text("A change lands between frames, and on no reading the last rung holds.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("FIXED")
                        .font(.system(size: 11, weight: .bold))
                        .kerning(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(LL.controlFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Toggle("EV thresholds always visible", isOn: $evAlwaysVisible)
                    .font(.system(size: 16))
            } header: {
                Text("Boundaries")
            }

            Section {
                if !isArmed {
                    Button("Use this ladder") {
                        selectedID = isBuiltIn ? nil : ladderID
                    }
                    .foregroundStyle(LL.accent)
                } else {
                    Label("Armed for the next Ladder shoot", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                }
                Button("Duplicate") {
                    let copy = store.duplicate(ladder)
                    path.append(.editor(copy.id))
                }
                .foregroundStyle(LL.accent)
                if !isBuiltIn {
                    Button("Delete ladder", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle(isBuiltIn ? ladder.name : (name.isEmpty ? ladder.name : name))
        #if os(iOS)
        // Inline: the built-in's full name is 26 characters, which a large
        // title truncates on a 393 pt phone ("Bright & Fast, Dark & S…").
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { name = ladder.name }
        .confirmationDialog("Delete this ladder?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if selectedID == ladderID { selectedID = nil }
                store.delete(id: ladderID)
                path.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shoots made with it keep their own record; only the table goes.")
        }
    }

    private func thresholdText(at index: Int) -> String {
        guard let bound = ladder.rungs[index].lowerBoundEV else { return "darker" }
        return "≥ \(LightLadderFormat.ev(bound))"
    }

    /// Moves rung `index`'s threshold, keeping half an EV from both
    /// neighbours so the ladder stays gap-free and strictly descending.
    private func moveThreshold(_ index: Int, to ev: Double) {
        guard !isBuiltIn, var edited = store.ladder(id: ladderID),
              index < edited.rungs.count - 1 else { return }
        let above = index > 0 ? (edited.rungs[index - 1].lowerBoundEV ?? LightLadder.drawingTopEV) : LightLadder.drawingTopEV
        let below = index + 1 < edited.rungs.count - 1
            ? (edited.rungs[index + 1].lowerBoundEV ?? LightLadder.drawingBottomEV)
            : LightLadder.drawingBottomEV
        let clamped = min(max(ev, below + 0.5), above - 0.5)
        edited.rungs[index].lowerBoundEV = (clamped * 2).rounded() / 2
        store.update(edited)
    }

    /// A new rung below the selected one (or at the bottom), splitting the
    /// span it lands in and copying the levers it inherits.
    private func addRung() {
        guard !isBuiltIn, var edited = store.ladder(id: ladderID), !edited.rungs.isEmpty else { return }
        let anchor = selectedRungID.flatMap { edited.index(of: $0) } ?? edited.rungs.count - 1
        let above = edited.rungs[anchor]
        let top = above.lowerBoundEV ?? (anchor > 0 ? (edited.rungs[anchor - 1].lowerBoundEV ?? LightLadder.drawingTopEV) : LightLadder.drawingTopEV)
        let bottom = anchor + 1 < edited.rungs.count
            ? (edited.rungs[anchor + 1].lowerBoundEV ?? LightLadder.drawingBottomEV)
            : LightLadder.drawingBottomEV
        var rung = above
        rung.id = UUID()
        rung.name = "Rung \(edited.rungs.count + 1)"
        if above.lowerBoundEV == nil {
            // Splitting the last rung: the old last takes a bound, the new
            // one is "and darker".
            let split = ((top + bottom) / 2 * 2).rounded() / 2
            edited.rungs[anchor].lowerBoundEV = split
            rung.lowerBoundEV = nil
        } else {
            let split = ((top + bottom) / 2 * 2).rounded() / 2
            rung.lowerBoundEV = split
            edited.rungs[anchor].lowerBoundEV = max(above.lowerBoundEV ?? split, split + 0.5)
        }
        edited.rungs.insert(rung, at: anchor + 1)
        store.update(edited)
        selectedRungID = rung.id
    }

    private func deleteRungs(at offsets: IndexSet) {
        guard !isBuiltIn, var edited = store.ladder(id: ladderID) else { return }
        for index in offsets.sorted(by: >) where edited.rungs.count > 1 && index < edited.rungs.count {
            if selectedRungID == edited.rungs[index].id { selectedRungID = nil }
            edited.rungs.remove(at: index)
        }
        store.update(edited)
    }
}

private struct RungRow: View {
    let rung: Rung
    let index: Int
    let count: Int
    let threshold: String?
    let isSelected: Bool
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LadderPalette.color(rung: index, of: count))
                    .frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rung.name)
                        .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(rung.shortLeverSummary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let threshold {
                    Text(threshold)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if let note, isSelected {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(LL.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// The whole ladder in 60 pt: one band per rung at its EV span inside 16 … −2,
/// the selected band ringed, EV ticks beneath. Drag a divider to move a
/// threshold; tap a band to select its rung.
struct LadderRibbon: View {
    let ladder: LightLadder
    let selectedRungID: UUID?
    let editable: Bool
    let onSelect: (UUID) -> Void
    /// Called once, when a divider drag ends, with the rung index whose lower
    /// bound moved and the EV it landed on.
    let onMoveThreshold: (Int, Double) -> Void

    @State private var dragging: (index: Int, ev: Double)?

    private static let top = LightLadder.drawingTopEV
    private static let bottom = LightLadder.drawingBottomEV

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(Array(ladder.rungs.enumerated()), id: \.element.id) { index, rung in
                        let upper = upperBound(at: index)
                        let lower = lowerBound(at: index)
                        let x0 = x(upper, width: width)
                        let x1 = x(lower, width: width)
                        Rectangle()
                            .fill(LadderPalette.color(rung: index, of: ladder.rungs.count))
                            .frame(width: max(x1 - x0, 0), height: 60)
                            .overlay {
                                if rung.id == selectedRungID {
                                    Rectangle().strokeBorder(LL.amber, lineWidth: 3)
                                }
                            }
                            .offset(x: x0)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(rung.id) }
                    }
                    ForEach(0..<max(ladder.rungs.count - 1, 0), id: \.self) { index in
                        let bound = lowerBound(at: index)
                        let position = x(bound, width: width)
                        Rectangle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 2, height: 60)
                            .offset(x: position - 1)
                            .allowsHitTesting(false)
                        if editable {
                            Color.clear
                                .frame(width: 28, height: 60)
                                .contentShape(Rectangle())
                                .offset(x: position - 14)
                                .gesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            dragging = (index, clampedEV(for: value.location.x, width: width, index: index))
                                        }
                                        .onEnded { value in
                                            let ev = clampedEV(for: value.location.x, width: width, index: index)
                                            dragging = nil
                                            onMoveThreshold(index, ev)
                                        })
                        }
                    }
                }
                // Leading, explicitly: the stack's natural width is its widest
                // band, and a centred frame would shift every offset band by
                // half the difference — the first sim screenshot had Daylight
                // starting at EV 11 and Night clipped off the right edge.
                .frame(width: width, height: 60, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.09), radius: 6, y: 3)
            }
            .frame(height: 60)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    tick(Self.top, width: width, leading: true)
                    ForEach(0..<max(ladder.rungs.count - 1, 0), id: \.self) { index in
                        tick(lowerBound(at: index), width: width, leading: true)
                    }
                    tick(Self.bottom, width: width, leading: false)
                }
            }
            .frame(height: 14)
        }
    }

    private func tick(_ ev: Double, width: CGFloat, leading: Bool) -> some View {
        Text(LightLadderFormat.ev(ev))
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize()
            .offset(x: leading ? x(ev, width: width) + 2 : width - 16)
    }

    private func x(_ ev: Double, width: CGFloat) -> CGFloat {
        CGFloat((Self.top - ev) / (Self.top - Self.bottom)) * width
    }

    private func ev(forX x: CGFloat, width: CGFloat) -> Double {
        Self.top - Double(x / max(width, 1)) * (Self.top - Self.bottom)
    }

    private func clampedEV(for x: CGFloat, width: CGFloat, index: Int) -> Double {
        let above = index > 0 ? (ladder.rungs[index - 1].lowerBoundEV ?? Self.top) : Self.top
        let below = index + 1 < ladder.rungs.count - 1
            ? (ladder.rungs[index + 1].lowerBoundEV ?? Self.bottom) : Self.bottom
        let raw = ev(forX: x, width: width)
        return (min(max(raw, below + 0.5), above - 0.5) * 2).rounded() / 2
    }

    private func lowerBound(at index: Int) -> Double {
        if let dragging, dragging.index == index { return dragging.ev }
        return ladder.rungs[index].lowerBoundEV ?? Self.bottom
    }

    private func upperBound(at index: Int) -> Double {
        index == 0 ? Self.top : min(lowerBound(at: index - 1), Self.top)
    }
}

// MARK: - The rung

/// Five levers in three sections whose headers carry the thesis: three are
/// constraints handed to the servo, two step at the boundary. Feasibility and
/// adjacency are stated at the foot, never silently corrected.
struct LightRungView: View {
    @ObservedObject var store: LightLadderStore
    let ladderID: UUID
    let rungID: UUID
    @State private var draft: Rung

    private static let intervalOptions: [Double] = [0.5, 1, 2, 3, 5, 10, 15, 20, 30, 60]
    private static let shutterOptions: [Double] = [
        1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15,
        1.0 / 8, 1.0 / 4, 1.0 / 2, 1,
    ]

    init(store: LightLadderStore, ladderID: UUID, rungID: UUID) {
        self.store = store
        self.ladderID = ladderID
        self.rungID = rungID
        let rung = store.ladder(id: ladderID)?.rungs.first { $0.id == rungID }
            ?? Rung(name: "Rung", lowerBoundEV: nil, intervalSeconds: 2, blendFrames: 1)
        _draft = State(initialValue: rung)
    }

    private var ladder: LightLadder { store.ladder(id: ladderID) ?? .builtIn }
    /// The ladder as it would be with the draft in place — what the messages
    /// and the range description are computed from.
    private var previewLadder: LightLadder {
        var copy = ladder
        if let index = copy.index(of: rungID) { copy.rungs[index] = draft }
        return copy
    }
    private var index: Int { ladder.index(of: rungID) ?? 0 }
    private var isBuiltIn: Bool { ladderID == LightLadder.builtInID }
    private var isLast: Bool { index == ladder.rungs.count - 1 }
    private var formatInfo: LightLadderFormatInfo { store.lastKnownFormat }
    private var format: HolyGrailRampEngine.HardwareLimits { formatInfo.limits }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $draft.name)
                    .font(.system(size: 16))
                    .disabled(isBuiltIn)
            }

            Section {
                if isLast {
                    Text("and darker · the last rung has no lower bound")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                } else {
                    stepperRow("Scene EV and brighter",
                               value: LightLadderFormat.ev(draft.lowerBoundEV ?? 0),
                               onDecrement: { moveThreshold(by: -0.5) },
                               onIncrement: { moveThreshold(by: 0.5) })
                }
            } header: {
                Text("Applies at")
            } footer: {
                Text(appliesFooter)
            }

            Section {
                isoRow
                shutterRow
                whiteBalanceRow
            } header: {
                Text("Exposure — handed to the servo")
            }

            Section {
                stepperRow("Every",
                           value: LightLadderFormat.seconds(draft.intervalSeconds),
                           onDecrement: { stepInterval(-1) },
                           onIncrement: { stepInterval(1) })
                stepperRow("Blend",
                           value: draft.blendFrames <= 1 ? "off" : "\(draft.blendFrames)",
                           onDecrement: { draft.blendFrames = max(1, draft.blendFrames - 1) },
                           onIncrement: { draft.blendFrames = min(20, draft.blendFrames + 1) })
            } header: {
                Text("Pacing — steps at the boundary")
            }

            Section {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    MessageCard(message: message)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
        }
        .disabled(isBuiltIn)
        .navigationTitle(draft.name)
        .onChange(of: draft) { _ in commit() }
    }

    // MARK: Rows

    private var isoRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ISO").font(.system(size: 16))
                    Text(isoSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("ISO", selection: isoKindBinding) {
                    Text("Min").tag(ISOKind.min)
                    Text("Auto").tag(ISOKind.auto)
                    Text("Max").tag(ISOKind.max)
                    Text("Value").tag(ISOKind.value)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            if case .value(let iso) = draft.iso {
                stepperRow("ISO value", value: "\(Int(iso.rounded()))",
                           onDecrement: { stepISO(by: -1) },
                           onIncrement: { stepISO(by: 1) })
            }
        }
    }

    private var shutterRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shutter").font(.system(size: 16))
                    Text(shutterSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Shutter", selection: shutterKindBinding) {
                    Text("Auto").tag(ShutterKind.auto)
                    Text("Auto, capped").tag(ShutterKind.capped)
                    Text("Pinned").tag(ShutterKind.pinned)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            switch draft.shutter {
            case .auto:
                EmptyView()
            case .autoCapped(let cap):
                stepperRow("Cap", value: LightLadderFormat.seconds(cap),
                           onDecrement: { stepShutter(-1) }, onIncrement: { stepShutter(1) })
            case .value(let pin):
                stepperRow("Pinned at", value: LightLadderFormat.seconds(pin),
                           onDecrement: { stepShutter(-1) }, onIncrement: { stepShutter(1) })
            }
        }
    }

    private var whiteBalanceRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("White balance").font(.system(size: 16))
                Text(draft.whiteBalance == .auto
                     ? "Tracked — slew-limited, never continuous AWB"
                     : "Frozen at arm")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("White balance", selection: $draft.whiteBalance) {
                Text("Auto").tag(WhiteBalanceChoice.auto)
                Text("Locked").tag(WhiteBalanceChoice.locked)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 150)
        }
    }

    private func stepperRow(_ title: String, value: String,
                            onDecrement: @escaping () -> Void,
                            onIncrement: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 16))
            Spacer()
            HStack(spacing: 0) {
                Button(action: onDecrement) {
                    Text("−").font(.system(size: 17)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                Text(value)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(minWidth: 46)
                Button(action: onIncrement) {
                    Text("+").font(.system(size: 17)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
            .background(LL.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: Copy

    private var appliesFooter: String {
        let range = previewLadder.rangeDescription(at: index)
        if isLast {
            return "The last rung has no lower bound: \(range)."
        }
        if index > 0 {
            return "Shown as \(range) because \(ladder.rungs[index - 1].name) sits above it. Only the lower bound is stored, so the ladder can never gap or overlap."
        }
        return "Shown as \(range). Only the lower bound is stored, so the ladder can never gap or overlap."
    }

    private var isoSubtitle: String {
        let lens = formatInfo.lensName
        let lo = Int(format.minISO.rounded()), hi = Int(format.maxISO.rounded())
        switch draft.iso {
        case .auto: return "Auto · \(lo)–\(hi) on \(lens)"
        case .min: return "Min · \(lo) on \(lens)"
        case .max: return "Max · \(hi) on \(lens)"
        case .value(let v): return "\(Int(v.rounded())) · \(lo)–\(hi) on \(lens)"
        }
    }

    private var shutterSubtitle: String {
        let effective = draft.effectiveShutterCeiling(within: format)
        switch draft.shutter {
        case .auto:
            return "Auto, up to \(LightLadderFormat.seconds(effective)) at this pacing"
        case .autoCapped(let cap):
            return effective + 1e-9 < cap
                ? "Auto, capped at \(LightLadderFormat.seconds(cap)) · \(LightLadderFormat.seconds(effective)) at this pacing"
                : "Auto, capped at \(LightLadderFormat.seconds(cap))"
        case .value(let pin):
            return "Pinned — a manual lock with ISO pinned too" + (effective + 1e-9 < pin ? " · \(LightLadderFormat.seconds(effective)) at this pacing" : "")
        }
    }

    private var messages: [LightLadderAdvice.Message] {
        LightLadderAdvice.messages(for: index, in: previewLadder, format: format)
    }

    // MARK: Edits

    private enum ISOKind: Hashable { case min, auto, max, value }
    private enum ShutterKind: Hashable { case auto, capped, pinned }

    private var isoKindBinding: Binding<ISOKind> {
        Binding(
            get: {
                switch draft.iso {
                case .min: return .min
                case .auto: return .auto
                case .max: return .max
                case .value: return .value
                }
            },
            set: { kind in
                switch kind {
                case .min: draft.iso = .min
                case .auto: draft.iso = .auto
                case .max: draft.iso = .max
                case .value:
                    if case .value = draft.iso { return }
                    draft.iso = .value(min(max(400, format.minISO), format.maxISO))
                }
            })
    }

    private var shutterKindBinding: Binding<ShutterKind> {
        Binding(
            get: {
                switch draft.shutter {
                case .auto: return .auto
                case .autoCapped: return .capped
                case .value: return .pinned
                }
            },
            set: { kind in
                switch kind {
                case .auto: draft.shutter = .auto
                case .capped:
                    if case .autoCapped = draft.shutter { return }
                    draft.shutter = .autoCapped(1)
                case .pinned:
                    if case .value = draft.shutter { return }
                    draft.shutter = .value(1)
                }
            })
    }

    private func moveThreshold(by delta: Double) {
        guard !isLast, let current = draft.lowerBoundEV else { return }
        let above = index > 0 ? (ladder.rungs[index - 1].lowerBoundEV ?? LightLadder.drawingTopEV) : LightLadder.drawingTopEV
        let below = index + 1 < ladder.rungs.count - 1
            ? (ladder.rungs[index + 1].lowerBoundEV ?? LightLadder.drawingBottomEV)
            : LightLadder.drawingBottomEV
        draft.lowerBoundEV = min(max(current + delta, below + 0.5), above - 0.5)
    }

    private func stepInterval(_ direction: Int) {
        let options = Self.intervalOptions
        let current = draft.intervalSeconds
        if direction > 0 {
            draft.intervalSeconds = options.first { $0 > current + 1e-9 } ?? current
        } else {
            draft.intervalSeconds = options.last { $0 < current - 1e-9 } ?? current
        }
    }

    private func stepShutter(_ direction: Int) {
        let options = Self.shutterOptions
        func next(_ current: Double) -> Double {
            direction > 0
                ? (options.first { $0 > current * 1.01 } ?? current)
                : (options.last { $0 < current * 0.99 } ?? current)
        }
        switch draft.shutter {
        case .auto: break
        case .autoCapped(let cap): draft.shutter = .autoCapped(next(cap))
        case .value(let pin): draft.shutter = .value(next(pin))
        }
    }

    /// Third-stop steps inside the lens's range.
    private func stepISO(by direction: Int) {
        guard case .value(let iso) = draft.iso else { return }
        let factor = pow(2.0, Double(direction) / 3.0)
        let stepped = Float((Double(iso) * factor).rounded())
        draft.iso = .value(min(max(stepped, format.minISO), format.maxISO))
    }

    private func commit() {
        guard !isBuiltIn, var edited = store.ladder(id: ladderID),
              let i = edited.index(of: rungID) else { return }
        var rung = draft
        rung.name = rung.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? edited.rungs[i].name : rung.name
        guard edited.rungs[i] != rung else { return }
        edited.rungs[i] = rung
        store.update(edited)
    }
}

private struct MessageCard: View {
    let message: LightLadderAdvice.Message

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 15, height: 15)
                .overlay {
                    Text(glyph)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 1)
            Text(message.text)
                .font(.system(size: 11.5))
                .foregroundStyle(LL.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var color: Color {
        switch message.kind {
        case .fits: return Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
        case .note: return Color.secondary
        case .warning: return LL.accent
        }
    }

    private var glyph: String {
        switch message.kind {
        case .fits: return "✓"
        case .note: return "i"
        case .warning: return "!"
        }
    }

    private var tint: Color {
        switch message.kind {
        case .fits: return Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255).opacity(0.12)
        case .note: return LL.controlFill.opacity(0.6)
        case .warning: return LL.amber.opacity(0.20)
        }
    }
}

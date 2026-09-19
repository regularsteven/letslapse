import SwiftUI
import LetsLapseKit

/// AUTO APPLY — the section on a preset's and a LUT's screen that says
/// which new shoots start on it (docs/presets-auto-apply.md). One "Auto
/// apply to" row whose menu adds or drops whole modes, or everything; then
/// a row per mode the preset holds, with that mode's filter. Every choice
/// is a set of slots against `AutoApplyStore`, and a choice that would take
/// slots from another preset stops at a confirmation that names what goes
/// — the other preset's rule shrinks to what it keeps, which its own screen
/// then shows. Narrowing, and None, never ask: they only let go.
struct AutoApplySection: View {
    let presetID: UUID
    let presetName: String
    /// The footer's noun: a LUT starts a shoot "at the strength above".
    let isLUT: Bool

    @ObservedObject private var store = AutoApplyStore.shared

    /// A change waiting on the dialog: what to take, what of this preset's
    /// own to let go in the same change (a filter that narrows one way and
    /// widens another), and the words.
    private struct Pending {
        var assign: Set<AutoApplySlot>
        var release: Set<AutoApplySlot>
        var title: String
        var conflicts: [AutoApplyRules.Conflict]
    }
    @State private var pending: Pending?

    private var owned: Set<AutoApplySlot> { store.slots(for: presetID) }

    var body: some View {
        Section {
            HStack {
                Text("Auto apply to")
                Spacer()
                Menu {
                    Button { store.release(presetID) } label: {
                        menuItem("None", chosen: owned.isEmpty)
                    }
                    Button {
                        request(assign: AutoApplySlot.all, release: [], title: "Apply \(presetName) to every shoot?")
                    } label: {
                        menuItem("Everything – All shoots", chosen: owned == AutoApplySlot.all)
                    }
                    Divider()
                    ForEach(AutoApplyMode.allCases, id: \.self) { mode in
                        Button { toggle(mode) } label: {
                            menuItem(mode.displayName, chosen: holds(mode))
                        }
                    }
                } label: {
                    valueLabel(store.rules.summary(for: presetID))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            // The dialog hangs off the row, not the section: a modifier on
            // a `Section` inside a `List` turns it into one row.
            .confirmationDialog(
                pending?.title ?? "", isPresented: dialogShown, titleVisibility: .visible
            ) {
                Button("Apply") { commitPending() }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text(pending.map { message($0) } ?? "")
            }

            ForEach(store.rules.modes(for: presetID), id: \.self) { mode in
                HStack {
                    Text("\(mode.displayName) for")
                    Spacer()
                    Menu {
                        ForEach(AutoApplyFilter.options(for: mode), id: \.self) { filter in
                            Button { choose(filter, in: mode) } label: {
                                menuItem(filter.label, chosen: AutoApplyFilter.canonical(for: owned, in: mode) == filter)
                            }
                        }
                    } label: {
                        valueLabel(AutoApplyFilter.label(for: owned, in: mode))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        } header: {
            Text("Auto apply")
        } footer: {
            Text(footerText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footerText: String {
        isLUT
            ? "New shoots that match start on this LUT at the strength above. Nothing already in your library changes."
            : "New shoots that match start on this preset. Nothing already in your library changes."
    }

    private var dialogShown: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    // MARK: Rows

    /// The Settings cards' value idiom: the value and a chevron pair.
    private func valueLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func menuItem(_ text: String, chosen: Bool) -> some View {
        if chosen {
            Label(text, systemImage: "checkmark")
        } else {
            Text(text)
        }
    }

    // MARK: Choices

    private func holds(_ mode: AutoApplyMode) -> Bool {
        !store.rules.slots(for: presetID, in: mode).isEmpty
    }

    /// The top row's mode items: on takes the whole mode, off lets it go.
    private func toggle(_ mode: AutoApplyMode) {
        let slots = AutoApplySlot.slots(in: mode)
        if holds(mode) {
            store.release(slots, from: presetID)
        } else {
            request(assign: slots, release: [], title: "Apply \(presetName) to \(mode.displayName)?")
        }
    }

    /// A mode row's filter: exactly that set within the mode.
    private func choose(_ filter: AutoApplyFilter, in mode: AutoApplyMode) {
        let target = filter.slots(in: mode)
        let held = store.rules.slots(for: presetID, in: mode)
        let release = held.subtracting(target)
        let assign = target.subtracting(held)
        if assign.isEmpty {
            store.release(release, from: presetID)
        } else {
            let title = filter == .all
                ? "Apply \(presetName) to \(mode.displayName)?"
                : "Apply \(presetName) to \(mode.displayName) · \(filter.label)?"
            request(assign: assign, release: release, title: title)
        }
    }

    /// Straight through when nothing is taken from anyone; else the dialog.
    private func request(assign: Set<AutoApplySlot>, release: Set<AutoApplySlot>, title: String) {
        let conflicts = store.conflicts(assigning: assign, to: presetID)
        if conflicts.isEmpty {
            store.apply(assigning: assign, releasing: release, for: presetID)
        } else {
            pending = Pending(assign: assign, release: release, title: title, conflicts: conflicts)
        }
    }

    private func commitPending() {
        guard let pending else { return }
        store.apply(assigning: pending.assign, releasing: pending.release, for: presetID)
        self.pending = nil
    }

    /// "Doing this removes: “Flat Day” on Photo shoots · JPEG Flat ON.
    /// “Punchy” on Interval shoots · All. “Flat Day” keeps Photo shoots ·
    /// JPEG Standard." — one sentence per preset taken from, then one per
    /// preset that keeps something.
    private func message(_ pending: Pending) -> String {
        var sentences = pending.conflicts.map { conflict in
            "“\(store.name(of: conflict.presetID))” on \(AutoApplyRules.describe(conflict.slots))."
        }
        if !sentences.isEmpty { sentences[0] = "Doing this removes: " + sentences[0] }
        for conflict in pending.conflicts where !conflict.remaining.isEmpty {
            sentences.append("“\(store.name(of: conflict.presetID))” keeps \(AutoApplyRules.describe(conflict.remaining)).")
        }
        return sentences.joined(separator: " ")
    }
}

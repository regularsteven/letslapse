import LetsLapseKit
import SwiftUI

/// The layer's copy field: a multi-line `TextField` that also reports where
/// the caret or selection is, so the run toolbar knows which word it is
/// styling. "Tap a word in the field to style just that word."
///
/// Selection read-back needs `TextSelection` (iOS 18 / macOS 15). On the
/// older floors the field is the plain one and the toolbar's controls act
/// on the whole layer — the copy still edits, nothing is lost, only the
/// per-word target is unavailable there.
struct OverlayCopyField: View {
    @Binding var text: String
    let focused: FocusState<UUID?>.Binding
    let layerID: UUID
    /// The character-offset range the toolbar should style: the selection
    /// when there is one, else the word under the caret, else nil (whole
    /// layer). Fired on every caret move.
    let onTarget: (Range<Int>?) -> Void
    let onEditingChanged: () -> Void

    var body: some View {
        if #available(iOS 18, macOS 15, *) {
            SelectionAwareCopyField(
                text: $text, focused: focused, layerID: layerID,
                onTarget: onTarget, onEditingChanged: onEditingChanged)
        } else {
            TextField(
                "Text — press Return for a new line",
                text: Binding(get: { text }, set: { text = $0; onEditingChanged() }),
                axis: .vertical)
                .lineLimit(1...6)
                .focused(focused, equals: layerID)
                .modifier(OverlayCopyFieldStyle())
        }
    }
}

/// The field's chrome: 14pt type in a bordered box (1px primary 22%, radius
/// 6), the design's copy field on both platforms.
struct OverlayCopyFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: OverlayPanelMetrics.copyFieldMinHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LL.cardBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
    }
}

@available(iOS 18, macOS 15, *)
private struct SelectionAwareCopyField: View {
    @Binding var text: String
    let focused: FocusState<UUID?>.Binding
    let layerID: UUID
    let onTarget: (Range<Int>?) -> Void
    let onEditingChanged: () -> Void

    @State private var selection: TextSelection?

    var body: some View {
        TextField(
            "Text — press Return for a new line",
            text: Binding(
                get: { text },
                set: { next in
                    guard next != text else { return }
                    // The selection holds indices of the text it was made
                    // in. SwiftUI's field coordinator pushes the selection
                    // it still holds back into the NSTextView on the next
                    // update — after a select-all-and-type that range
                    // reaches past the new, shorter text and Foundation
                    // traps ("String index is out of bounds", 2026-09-04).
                    // Replace it with the caret the edit leaves behind — the
                    // end of what was typed, an index made in the NEW text —
                    // so what gets pushed back is valid, and the run toolbar
                    // keeps tracking the word being typed.
                    let caret = TextOverlayContent.caretAfterEdit(from: text, to: next)
                    selection = TextSelection(insertionPoint: next.index(next.startIndex, offsetBy: caret))
                    text = next
                    onEditingChanged()
                }),
            selection: $selection,
            axis: .vertical)
            .lineLimit(1...6)
            .focused(focused, equals: layerID)
            .modifier(OverlayCopyFieldStyle())
            .onChange(of: selection) { _, next in
                onTarget(target(for: next))
            }
            .onChange(of: focused.wrappedValue) { _, next in
                if next != layerID { onTarget(nil) }
            }
    }

    /// Selection → the range the toolbar styles. A caret inside (or at the
    /// end of) a word expands to that word; a caret on whitespace is no
    /// target at all. The arithmetic lives in the Kit
    /// (`TextOverlayContent.styleTarget`), clamped and under test, because
    /// the indices may belong to an earlier value of the text.
    private func target(for selection: TextSelection?) -> Range<Int>? {
        guard let selection else { return nil }
        let range: Range<String.Index>?
        switch selection.indices {
        case .selection(let r): range = r
        case .multiSelection(let set): range = set.ranges.first
        @unknown default: range = nil
        }
        guard let range else { return nil }
        return TextOverlayContent.styleTarget(for: range, in: text)
    }
}

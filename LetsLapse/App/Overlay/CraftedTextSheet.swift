import LetsLapseKit
import SwiftUI

/// "Add Crafted Text" — a brief in, laid-out layers out.
///
/// Four states, and which one it opens in is decided by whether a model is
/// installed: with one it asks what you want to communicate and offers to
/// either split what you wrote (Final copy) or suggest directions (Needs
/// work); without one it is a plain one-line-per-layer field with an honest
/// notice about what AI would add. Both paths end in the same place — parts
/// handed to `CraftedTextLayout`, which does the typography.
struct CraftedTextSheet: View {
    let accent: Color
    let onAccent: Color
    /// The chosen lines, already parts. The caller lays them out and inserts
    /// them, so this sheet never touches the document.
    let onAdd: ([CraftedTextPart]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var brief = ""
    @State private var mode: Mode = .final
    @State private var step: Step = .prompt
    @State private var candidates: [String] = []
    @State private var thinkingTitle = ""
    @State private var noticeText: String?
    @State private var work: Task<Void, Never>?

    private let service = CraftedTextService.shared

    private enum Mode { case final, needs }
    private enum Step: Equatable { case prompt, thinking, candidates, simple }

    private typealias M = OverlayPanelMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch step {
            case .prompt: promptStep
            case .thinking: thinkingStep
            case .candidates: candidatesStep
            case .simple: simpleStep
            }
            // The sheet is a card on the Mac and a full-height sheet on the
            // phone; this keeps the content at the top on both instead of
            // letting the brief field stretch to fill a phone screen.
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        #if os(macOS)
        .frame(width: 480, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        #else
        // The Text tab is the dark editor, and a sheet raised from it that
        // came up white would look like a different app.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LL.ink)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .onAppear {
            // No model, no pretence: the plain field IS the feature here.
            step = service.isAvailable ? .prompt : .simple
        }
        .onDisappear { work?.cancel() }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(accent)
            Text("CRAFTED TEXT")
                .font(.system(size: 11, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                work?.cancel()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(M.controlFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 19, weight: .bold))
            .kerning(-0.2)
            .foregroundStyle(.primary)
    }

    // MARK: - Prompt

    private var promptStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("What would you like to communicate?")
            briefField(placeholder: "Type the words, or describe what you need…",
                       minHeight: 88)
            HStack(spacing: 8) {
                modeCard(.final, title: "Final copy",
                         detail: "Split into lines and laid out.")
                modeCard(.needs, title: "Needs work",
                         detail: "Describe it; pick from a few candidates.")
            }
            HStack(spacing: 10) {
                Text("On device · \(CraftedTextService.modelDisplayName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                sendButton("Send") { send() }
            }
            if let noticeText {
                footnote(noticeText)
            }
        }
    }

    private func modeCard(_ value: Mode, title: String, detail: String) -> some View {
        let on = mode == value
        return Button {
            mode = value
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .strokeBorder(on ? accent : Color.primary.opacity(0.25),
                                  lineWidth: on ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? accent.opacity(0.06) : M.controlFill))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(on ? accent.opacity(0.55) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: - Thinking

    private var thinkingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(thinkingTitle)
            Text("“\(brief.trimmingCharacters(in: .whitespacesAndNewlines))”")
                .font(.system(size: 13))
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(3)
            // Indeterminate on purpose: a generation has no honest progress
            // to report, and a bar that pretends to know is a lie the design
            // only got away with because its model was a timer.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(accent)
            footnote("\(CraftedTextService.modelDisplayName) · on device · nothing leaves this \(Self.deviceWord)")
        }
    }

    // MARK: - Candidates

    private var candidatesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Pick a direction")
            Text("Tap one to lay it out as final copy.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if candidates.isEmpty {
                footnote("The model didn't offer any directions. Edit the brief and try again.")
            }
            VStack(spacing: 8) {
                ForEach(candidates, id: \.self) { candidate in
                    Button {
                        brief = candidate
                        mode = .final
                        send()
                    } label: {
                        HStack(spacing: 10) {
                            Text(candidate)
                                .font(.system(size: 14))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(M.controlFill))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("‹ Edit brief") { step = .prompt }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                Spacer(minLength: 0)
                Button("More like these") { ask(more: true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
    }

    // MARK: - No model

    private var simpleStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Add text")
            Text("One line per layer. Lines stack top to bottom and follow each other in time.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            briefField(
                placeholder: "A little sand between your toes\nhelps wash away the woes",
                minHeight: 96)
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(accent)
                Text("Enable AI to enhance this experience")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text("Settings › AI Models ›")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(accent)
                    .fixedSize()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.08)))
            HStack {
                Spacer(minLength: 0)
                sendButton(lineCount > 1 ? "Add \(lineCount) lines" : "Add line") {
                    // No model to ask: every line the user typed is a layer,
                    // in their own words, in their own order.
                    add(lines.map { CraftedTextPart(copy: $0, priority: 2) })
                }
            }
        }
    }

    // MARK: - Shared bits

    private func briefField(placeholder: String, minHeight: CGFloat) -> some View {
        TextEditor(text: $brief)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            // A fixed height, not a minimum: inside a full-height sheet a
            // minimum is an invitation to take the whole screen.
            .frame(height: minHeight)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if brief.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
    }

    private func sendButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(onAccent)
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(Capsule().fill(accent))
        }
        .buttonStyle(.plain)
        .opacity(canSend ? 1 : 0.4)
        .disabled(!canSend)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static var deviceWord: String {
        #if os(macOS)
        "Mac"
        #else
        "device"
        #endif
    }

    private var lines: [String] {
        brief.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private var lineCount: Int { lines.count }

    private var canSend: Bool {
        !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Flow

    private func send() {
        guard canSend else { return }
        noticeText = nil
        if mode == .needs {
            ask(more: false)
        } else {
            thinkingTitle = "Splitting into lines…"
            step = .thinking
            work?.cancel()
            work = Task {
                let parts = await service.parts(for: brief)
                guard !Task.isCancelled else { return }
                add(parts)
            }
        }
    }

    private func ask(more: Bool) {
        thinkingTitle = more ? "Finding a few more…" : "Finding a few directions…"
        step = .thinking
        work?.cancel()
        work = Task {
            let found = await service.candidates(for: brief)
            guard !Task.isCancelled else { return }
            // "More like these" that returns nothing leaves what was already
            // on offer rather than emptying the list under the pointer.
            candidates = found.isEmpty && more ? candidates : found
            step = .candidates
        }
    }

    private func add(_ parts: [CraftedTextPart]) {
        guard !parts.isEmpty else {
            noticeText = "Nothing came back to lay out. Try rewording the brief."
            step = .prompt
            return
        }
        onAdd(parts)
        dismiss()
    }
}

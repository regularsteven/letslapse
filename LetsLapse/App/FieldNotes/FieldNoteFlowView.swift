import SwiftUI

// MARK: - Custom issue labels (user-level)

/// The Log Issue screen's checkable labels: five seeds plus whatever the user
/// has added through "Other" — customs persist at user level (not per
/// project) and stay checkable in every future issue log. Modeled on
/// `ResolutionPreferences`.
final class FieldNoteIssueLabels: ObservableObject {
    static let shared = FieldNoteIssueLabels()

    static let seedLabels = [
        "Focus", "Jumped frame(s)", "Auto stop", "Wrong resolution", "Wrong camera",
    ]

    @Published private(set) var customLabels: [String]

    private static let defaultsKey = "letslapse.fieldnotes.customIssueLabels"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customLabels = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    var allLabels: [String] { Self.seedLabels + customLabels }

    func addCustomLabel(_ raw: String) {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              !allLabels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame })
        else { return }
        customLabels.append(label)
        defaults.set(customLabels, forKey: Self.defaultsKey)
    }
}

// MARK: - The flow

/// The "+ Field note" flow: one reusable component behind both entry points
/// (project detail's action list and the New blended clip screen). A picker
/// offers Record Audio / Log Issue / Write Note; every sub-screen carries
/// "Add to project" (lower right) and Cancel, and Cancel closes the whole
/// flow — back to wherever the button lives.
struct FieldNoteFlowView: View {
    @EnvironmentObject var model: AppModel
    let capture: AppModel.CaptureProject
    /// Closes the presenting sheet (a pushed sub-screen's `dismiss` would
    /// only pop the stack).
    let onClose: () -> Void
    /// Fired after notes landed, so the presenter can refresh its list.
    var onSaved: () -> Void = {}

    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        RecordAudioNoteView(onCancel: onClose, onAdd: save)
                    } label: {
                        Label("Record Audio", systemImage: "mic")
                    }
                    NavigationLink {
                        LogIssueNoteView(onCancel: onClose, onAdd: save)
                    } label: {
                        Label("Log Issue", systemImage: "exclamationmark.triangle")
                    }
                    NavigationLink {
                        WriteNoteView(onCancel: onClose, onAdd: save)
                    } label: {
                        Label("Write Note", systemImage: "square.and.pencil")
                    }
                } footer: {
                    Text("Notes stay with “\(capture.displayTitle)” — they export and transfer with the project.")
                }
            }
            .navigationTitle("Field note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onClose() }
                }
            }
        }
        .alert(
            "Couldn't save the note",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Saves one or more notes (an audio note may arrive with a linked
    /// transcript note) and closes the flow. A failure keeps the flow open
    /// with the error named, and reports false so the sub-screen can leave
    /// its busy state.
    private func save(_ notes: [(note: FieldNote, audioURL: URL?)]) -> Bool {
        do {
            for entry in notes {
                try model.addFieldNote(entry.note, audioSourceURL: entry.audioURL, to: capture)
            }
            onSaved()
            onClose()
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}

// MARK: - Shared bottom bar

/// Every sub-screen's actions: Cancel closes the whole flow; "Add to
/// project" sits lower right, per the spec.
private struct FieldNoteActionBar: View {
    var addEnabled: Bool
    var busy = false
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onAdd) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Add to project")
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LL.accent)
            .disabled(!addEnabled || busy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Record Audio

private struct RecordAudioNoteView: View {
    let onCancel: () -> Void
    let onAdd: ([(note: FieldNote, audioURL: URL?)]) -> Bool

    @StateObject private var recorder = FieldNoteRecorder()
    /// The transparent speech review, started the moment a take lands so
    /// "Add to project" rarely has to wait on it.
    @State private var reviewTask: Task<String?, Never>?
    @State private var isSaving = false
    @State private var transcriptPrompt: TranscriptPrompt?

    private struct TranscriptPrompt: Identifiable {
        let id = UUID()
        let url: URL
        let duration: TimeInterval
        let transcript: String
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)

            Text(timeText)
                .font(.system(size: 40, weight: .medium).monospacedDigit())
                .foregroundStyle(recorder.phase == .recording ? .primary : .secondary)

            // Level readout: flat until sound moves it.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(LL.accent)
                        .frame(width: max(6, proxy.size.width * recorder.level))
                        .animation(.linear(duration: 0.05), value: recorder.level)
                }
            }
            .frame(width: 220, height: 6)
            .opacity(recorder.phase == .recording ? 1 : 0.35)

            Button {
                recorder.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(recorder.phase == .recording ? Color.red : LL.accent)
                        .frame(width: 72, height: 72)
                    Image(systemName: recorder.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.phase == .recording ? "Stop recording" : "Start recording")

            Text(hintText)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()

            FieldNoteActionBar(
                addEnabled: isFinished, busy: isSaving,
                onCancel: { recorder.discard(); onCancel() },
                onAdd: beginSave)
        }
        .navigationTitle("Record Audio")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: recorder.phase) { phase in
            guard case .finished(let url, _) = phase else { return }
            reviewTask = Task { await FieldNoteSpeechReview.transcript(of: url) }
        }
        .onDisappear {
            // Back-swipe or sheet teardown with an unsaved take: nothing to
            // keep. After a save the temp file has already been moved, so
            // this is a no-op.
            if !isSaving { recorder.discard() }
        }
        .confirmationDialog(
            "Spoken words were found. Save the transcript as a note too?",
            isPresented: Binding(
                get: { transcriptPrompt != nil },
                set: { if !$0 { transcriptPrompt = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save audio + note") {
                if let prompt = transcriptPrompt { finish(prompt, includeTextNote: true) }
            }
            Button("Just the audio") {
                if let prompt = transcriptPrompt { finish(prompt, includeTextNote: false) }
            }
        }
    }

    private var isFinished: Bool {
        if case .finished = recorder.phase { return true }
        return false
    }

    private var timeText: String {
        let seconds: TimeInterval
        switch recorder.phase {
        case .finished(_, let duration): seconds = duration
        default: seconds = recorder.elapsed
        }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private var hintText: String {
        switch recorder.phase {
        case .idle: return "Tap to record — a spoken memo, or ambient sound for a later soundtrack."
        case .denied: return "Microphone access is off for LetsLapse — enable it in system Settings."
        case .recording: return "Recording… tap to stop."
        case .finished: return "Take ready. Record again to replace it, or add it to the project."
        }
    }

    /// The transparent speech review decides the save shape: spoken words →
    /// offer a linked transcript note; anything else saves quietly.
    private func beginSave() {
        guard case .finished(let url, let duration) = recorder.phase, !isSaving else { return }
        isSaving = true
        Task {
            let transcript = await reviewTask?.value ?? nil
            await MainActor.run {
                if let transcript {
                    isSaving = false
                    transcriptPrompt = TranscriptPrompt(
                        url: url, duration: duration, transcript: transcript)
                } else {
                    finish(TranscriptPrompt(url: url, duration: duration, transcript: ""),
                           includeTextNote: false)
                }
            }
        }
    }

    private func finish(_ prompt: TranscriptPrompt, includeTextNote: Bool) {
        isSaving = true
        var audioNote = FieldNote(
            id: UUID(), kind: .audio, createdAt: Date(),
            durationSeconds: prompt.duration,
            transcript: prompt.transcript.isEmpty ? nil : prompt.transcript)
        var saves: [(note: FieldNote, audioURL: URL?)] = []
        if includeTextNote {
            let textNote = FieldNote(
                id: UUID(), kind: .text, createdAt: Date(),
                text: prompt.transcript, linkedNoteID: audioNote.id)
            audioNote.linkedNoteID = textNote.id
            saves = [(audioNote, prompt.url), (textNote, nil)]
        } else {
            saves = [(audioNote, prompt.url)]
        }
        if !onAdd(saves) { isSaving = false }
    }
}

// MARK: - Log Issue

private struct LogIssueNoteView: View {
    let onCancel: () -> Void
    let onAdd: ([(note: FieldNote, audioURL: URL?)]) -> Bool

    @ObservedObject private var labels = FieldNoteIssueLabels.shared
    @State private var selected: Set<String> = []
    @State private var showsCustomField = false
    @State private var customText = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("What went wrong?")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                        alignment: .leading, spacing: 8
                    ) {
                        ForEach(labels.allLabels, id: \.self) { label in
                            issueChip(label)
                        }
                        Button {
                            showsCustomField.toggle()
                        } label: {
                            chipLabel("Other…", ticked: showsCustomField)
                        }
                        .buttonStyle(.plain)
                    }

                    if showsCustomField {
                        TextField("Describe the issue", text: $customText)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(16)
            }
            FieldNoteActionBar(
                addEnabled: !selected.isEmpty || !trimmedCustom.isEmpty,
                onCancel: onCancel, onAdd: add)
        }
        .navigationTitle("Log Issue")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func issueChip(_ label: String) -> some View {
        Button {
            if selected.contains(label) {
                selected.remove(label)
            } else {
                selected.insert(label)
            }
        } label: {
            chipLabel(label, ticked: selected.contains(label))
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ text: String, ticked: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(ticked ? LL.accent : Color.secondary)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(ticked ? LL.accent.opacity(0.14) : Color.secondary.opacity(0.08)))
        .contentShape(Rectangle())
    }

    private var trimmedCustom: String {
        showsCustomField ? customText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private func add() {
        // Keep display order: seeds and existing customs as listed, a fresh
        // custom label last — and persisted for every future issue log.
        var chosen = labels.allLabels.filter { selected.contains($0) }
        let custom = trimmedCustom
        if !custom.isEmpty, !chosen.contains(where: { $0.caseInsensitiveCompare(custom) == .orderedSame }) {
            labels.addCustomLabel(custom)
            chosen.append(custom)
        }
        guard !chosen.isEmpty else { return }
        let note = FieldNote(
            id: UUID(), kind: .issue, createdAt: Date(), issueLabels: chosen)
        _ = onAdd([(note, nil)])
    }
}

// MARK: - Write Note

private struct WriteNoteView: View {
    let onCancel: () -> Void
    let onAdd: ([(note: FieldNote, audioURL: URL?)]) -> Bool

    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.08)))
                .frame(minHeight: 160)
                .padding(16)
            Spacer(minLength: 0)
            FieldNoteActionBar(
                addEnabled: !trimmed.isEmpty,
                onCancel: onCancel, onAdd: add)
        }
        .navigationTitle("Write Note")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        let note = FieldNote(id: UUID(), kind: .text, createdAt: Date(), text: trimmed)
        _ = onAdd([(note, nil)])
    }
}

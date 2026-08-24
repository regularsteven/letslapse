import Foundation

/// One field note on a project: a recorded audio memo (voice or ambient), a
/// structured issue log, or a written text note. Notes accumulate against the
/// project they describe and live inside its folder, so they export, back up
/// and transfer with the footage (spec: Project Field Notes, 2026-08-24).
struct FieldNote: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case audio, issue, text
    }

    var id: UUID
    var kind: Kind
    var createdAt: Date
    /// Text notes: the body. Also the body of a transcript note saved from an
    /// audio recording.
    var text: String? = nil
    /// Issue notes: the ticked labels, in display order.
    var issueLabels: [String]? = nil
    /// Audio notes: the `.m4a` file name inside the project's `notes/`.
    var audioFileName: String? = nil
    var durationSeconds: Double? = nil
    /// Audio notes: the on-device transcript, when the automatic speech
    /// review found spoken words. Stored on the audio note itself whether or
    /// not a linked text note was made from it.
    var transcript: String? = nil
    /// The other half of an audio ↔ transcript-note pair — a linked pair,
    /// not two orphans.
    var linkedNoteID: UUID? = nil

    /// The line a list preview shows for this note.
    var previewText: String? {
        switch kind {
        case .text: return text
        case .issue: return issueLabels?.joined(separator: " · ")
        case .audio: return transcript
        }
    }
}

// MARK: - Per-project storage

/// The notes live as `notes/notes.json` (manifest) plus audio files beside
/// it. `.lapse` export archives the whole project folder so notes ride along
/// for free; import moves the `notes` subfolder explicitly (see the archive
/// install path). Nothing here touches the library manifest — a note never
/// changes `formatVersion`.
extension AppModel {

    private static let fieldNotesFolderName = "notes"
    private static let fieldNotesManifestName = "notes.json"

    private func fieldNotesFolderURL(for capture: CaptureProject) -> URL {
        projectFolderURL(for: capture).appendingPathComponent(Self.fieldNotesFolderName)
    }

    private func fieldNotesManifestURL(for capture: CaptureProject) -> URL {
        fieldNotesFolderURL(for: capture).appendingPathComponent(Self.fieldNotesManifestName)
    }

    /// The audio file behind an audio note, for playback.
    func fieldNoteAudioURL(for note: FieldNote, in capture: CaptureProject) -> URL? {
        guard let name = note.audioFileName else { return nil }
        return fieldNotesFolderURL(for: capture).appendingPathComponent(name)
    }

    /// All notes on a project, newest first. Missing manifest = no notes;
    /// a torn manifest reads as empty rather than crashing the screen.
    func fieldNotes(for capture: CaptureProject) -> [FieldNote] {
        let url = fieldNotesManifestURL(for: capture)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let notes = (try? decoder.decode([FieldNote].self, from: data)) ?? []
        return notes.sorted { $0.createdAt > $1.createdAt }
    }

    /// Adds a note. For an audio note, `audioSourceURL` is the recorder's
    /// temp file, moved into the project as `<note-id>.m4a`.
    func addFieldNote(
        _ note: FieldNote, audioSourceURL: URL? = nil, to capture: CaptureProject
    ) throws {
        let folder = fieldNotesFolderURL(for: capture)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stored = note
        if let audioSourceURL {
            let fileName = "\(note.id.uuidString).m4a"
            try FileManager.default.moveItem(
                at: audioSourceURL, to: folder.appendingPathComponent(fileName))
            stored.audioFileName = fileName
        }
        var notes = fieldNotes(for: capture)
        notes.append(stored)
        try writeFieldNotes(notes, for: capture)
        invalidateStorageCache(for: capture.id)
    }

    /// Removes a note (and its audio file). The other half of a linked pair
    /// stays, with its link cleared.
    func deleteFieldNote(_ note: FieldNote, from capture: CaptureProject) {
        if let audio = fieldNoteAudioURL(for: note, in: capture) {
            try? FileManager.default.removeItem(at: audio)
        }
        var notes = fieldNotes(for: capture)
        notes.removeAll { $0.id == note.id }
        for index in notes.indices where notes[index].linkedNoteID == note.id {
            notes[index].linkedNoteID = nil
        }
        try? writeFieldNotes(notes, for: capture)
        invalidateStorageCache(for: capture.id)
    }

    private func writeFieldNotes(_ notes: [FieldNote], for capture: CaptureProject) throws {
        let folder = fieldNotesFolderURL(for: capture)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Oldest-first on disk (append order); readers sort for display.
        try encoder.encode(notes.sorted { $0.createdAt < $1.createdAt })
            .write(to: fieldNotesManifestURL(for: capture), options: .atomic)
    }
}

import Foundation
import SwiftUI

/// A grade the user named and kept: a built-in preset plus the slider values
/// layered on top. Saved app-wide rather than per project, so a look worked out
/// on one photo can be applied to the next one.
struct CustomPreset: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var basePreset: PhotoPreset
    var adjustments: PhotoAdjustments

    init(id: UUID = UUID(), name: String, basePreset: PhotoPreset, adjustments: PhotoAdjustments) {
        self.id = id
        self.name = name
        self.basePreset = basePreset
        self.adjustments = adjustments
    }
}

/// The app-wide store of saved grades, backed by one JSON file in Application
/// Support alongside the project library. Small enough to load once at first
/// use and hold in memory; every mutation rewrites the file atomically.
@MainActor
final class CustomPresetStore: ObservableObject {
    static let shared = CustomPresetStore()

    @Published private(set) var presets: [CustomPreset] = []

    /// Set when a save or delete couldn't be written to disk, so the UI can say
    /// so instead of silently dropping the preset.
    @Published var lastError: String?

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        // Sits next to the project library in the app's own Application Support
        // folder, matching where AppModel keeps everything else.
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LetsLapse", isDirectory: true)
            .appendingPathComponent("custom_presets.json")
        load()
    }

    // MARK: - Reading

    func preset(id: UUID) -> CustomPreset? {
        presets.first { $0.id == id }
    }

    // Which chip is lit is no longer a values lookup: a project carries its
    // `PresetState`, and a preset is shown as active only when the project is
    // actually on it. `PresetStateResolver` owns the matching now, snapshot
    // first, so a preset reworked after the fact doesn't reassign old projects.

    // MARK: - Writing

    /// Saves a new grade under `name`. A blank name is rejected; a name already
    /// in use overwrites that preset rather than adding a duplicate chip.
    @discardableResult
    func save(name: String, basePreset: PhotoPreset, adjustments: PhotoAdjustments) -> CustomPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let index = presets.firstIndex(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            presets[index].basePreset = basePreset
            presets[index].adjustments = adjustments
            persist()
            return presets[index]
        }

        let preset = CustomPreset(name: trimmed, basePreset: basePreset, adjustments: adjustments)
        presets.append(preset)
        persist()
        return preset
    }

    func delete(_ preset: CustomPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    func rename(_ preset: CustomPreset, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].name = trimmed
        persist()
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            presets = try JSONDecoder().decode([CustomPreset].self, from: data)
        } catch {
            // A corrupt file shouldn't take the photo viewer down with it — the
            // built-in presets still work, and the next save rewrites the file.
            presets = []
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Couldn't save your presets: \(error.localizedDescription)"
        }
    }
}

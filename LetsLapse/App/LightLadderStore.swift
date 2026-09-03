import Foundation
import SwiftUI
import LetsLapseKit

/// The app-wide store of **Light Ladders** — the user's own tables for
/// Interval's Ladder MODE — backed by `light_ladders.json` beside
/// `custom_presets.json` in the storage root. Small enough to load once and
/// hold in memory; every mutation rewrites the file atomically.
///
/// The built-in ladder (`LightLadder.builtIn`) is never in the file: it has a
/// fixed UUID, is served first from `ladders`, and refuses every mutation
/// except duplication — a shoot from six months ago still means what it
/// meant. Precedent: the built-in presets in `App/PresetState.swift`.
///
/// `light_ladders.json` is listed in `StorageLocation.libraryItemNames`, so a
/// Mac storage move carries it. See `docs/light-ladder.md` §5.
@MainActor
final class LightLadderStore: ObservableObject {
    static let shared = LightLadderStore()
    static let fileName = "light_ladders.json"

    /// The user's ladders, in the order they were made. Never contains the
    /// built-in.
    @Published private(set) var userLadders: [LightLadder] = []

    /// Set when a save or delete couldn't be written to disk, so the UI can
    /// say so instead of silently dropping the ladder.
    @Published var lastError: String?

    /// The lens the capture screen last armed Ladder on — what the rung screen
    /// resolves symbolic ISO against ("Auto · 54–3072 on Wide"). Set by
    /// `CameraController.setLadderPreview(enabled:)`; the wide-camera default
    /// stands in before any camera has been seen.
    @Published var lastKnownFormat = LightLadderFormatInfo.typicalWide

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? StorageRoot.current.appendingPathComponent(Self.fileName)
        load()
    }

    // MARK: - Reading

    /// Built-in first, then the user's.
    var ladders: [LightLadder] { [LightLadder.builtIn] + userLadders }

    func ladder(id: UUID) -> LightLadder? {
        if id == LightLadder.builtInID { return .builtIn }
        return userLadders.first { $0.id == id }
    }

    /// The ladder a remembered selection names, or the built-in when the id
    /// is nil or no longer resolves (deleted, or from another device's file).
    func resolve(id: UUID?) -> LightLadder {
        id.flatMap(ladder(id:)) ?? .builtIn
    }

    // MARK: - Writing

    /// A copy of any ladder — the only way to make one from the built-in.
    @discardableResult
    func duplicate(_ ladder: LightLadder, named name: String? = nil) -> LightLadder {
        let copy = ladder.cloned(named: name.map(Self.trimmed) ?? uniqueName(for: "\(ladder.name) (copy)"))
        userLadders.append(copy)
        persist()
        return copy
    }

    /// A fresh two-rung starter — bright and dark — that the editor grows.
    @discardableResult
    func createNew() -> LightLadder {
        let ladder = LightLadder(
            name: uniqueName(for: "New ladder"),
            rungs: [
                Rung(name: "Bright", lowerBoundEV: 8, iso: .min, shutter: .auto,
                     whiteBalance: .auto, intervalSeconds: 3, blendFrames: 5),
                Rung(name: "Dark", lowerBoundEV: nil, iso: .auto, shutter: .autoCapped(1),
                     whiteBalance: .auto, intervalSeconds: 2, blendFrames: 1),
            ])
        userLadders.append(ladder)
        persist()
        return ladder
    }

    /// Replaces a user ladder wholesale (the editor's Done). Normalised on
    /// the way in, so the file can never hold a gapped or unsorted table. The
    /// built-in is refused.
    func update(_ ladder: LightLadder) {
        guard !ladder.isBuiltIn,
              let index = userLadders.firstIndex(where: { $0.id == ladder.id }) else { return }
        var fixed = ladder.normalized()
        fixed.name = Self.trimmed(fixed.name).isEmpty ? userLadders[index].name : Self.trimmed(fixed.name)
        userLadders[index] = fixed
        persist()
    }

    func rename(id: UUID, to name: String) {
        let trimmed = Self.trimmed(name)
        guard !trimmed.isEmpty, id != LightLadder.builtInID,
              let index = userLadders.firstIndex(where: { $0.id == id }) else { return }
        userLadders[index].name = trimmed
        persist()
    }

    func delete(id: UUID) {
        guard id != LightLadder.builtInID else { return }
        userLadders.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Names

    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Sunrise", then "Sunrise 2", "Sunrise 3" — the built-in's name counts
    /// as taken too.
    private func uniqueName(for base: String) -> String {
        let taken = Set(ladders.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            // Decode-tolerant at the rung level (missing levers take their
            // defaults) and normalised per ladder; a built-in id that somehow
            // reached the file is dropped rather than shadowing the real one.
            userLadders = try JSONDecoder().decode([LightLadder].self, from: data)
                .filter { !$0.isBuiltIn && !$0.rungs.isEmpty }
                .map { $0.normalized() }
        } catch {
            // A corrupt file shouldn't take the capture screen down with it —
            // the built-in still works, and the next save rewrites the file.
            userLadders = []
            lastError = "Couldn't read your ladders: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(userLadders).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Couldn't save your ladders: \(error.localizedDescription)"
        }
    }
}


/// The envelope a rung's box is cut from, with the lens it belongs to.
struct LightLadderFormatInfo: Equatable {
    var lensName: String
    var limits: HolyGrailRampEngine.HardwareLimits

    /// An iPhone wide camera, as the design quotes it — the placeholder
    /// until a real format has been seen.
    static let typicalWide = LightLadderFormatInfo(
        lensName: "Wide (typical)",
        limits: HolyGrailRampEngine.HardwareLimits(
            minShutter: HolyGrailRampEngine.time(1.0 / 8000),
            maxShutter: HolyGrailRampEngine.time(1.0),
            minISO: 54, maxISO: 3072, aperture: 1.78))
}

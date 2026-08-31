import Foundation

/// Per-project overlay persistence for the spike: `overlays.json` beside the
/// project's other sidecars, the `FieldNoteStore` pattern. Deliberately NOT a
/// field on `CaptureProject` yet — this keeps experimental schema out of
/// `library.json` while the shape settles. Promotion to a manifest field (and
/// a `ProjectArchive.transferableSubfolders` ride-along) is a recorded
/// productization follow-up; until then overlays survive relaunches but do
/// not travel in `.lapse` archives or device transfers.
extension AppModel {

    private static let overlaysFileName = "overlays.json"

    private func overlaysURL(for capture: CaptureProject) -> URL {
        projectFolderURL(for: capture).appendingPathComponent(Self.overlaysFileName)
    }

    /// All overlays on a project. Missing file = none; a torn file reads as
    /// none rather than crashing the editor.
    func overlays(for capture: CaptureProject) -> [SceneOverlay] {
        guard let data = try? Data(contentsOf: overlaysURL(for: capture)) else { return [] }
        return (try? JSONDecoder().decode([SceneOverlay].self, from: data)) ?? []
    }

    /// Writes the full overlay list, removing the file when the list empties
    /// so a project that never had text never grows a sidecar.
    func setOverlays(_ overlays: [SceneOverlay], for capture: CaptureProject) {
        let url = overlaysURL(for: capture)
        guard !overlays.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(overlays) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

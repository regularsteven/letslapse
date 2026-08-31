import Foundation

/// Per-project overlay persistence for the spike: `overlays.json` beside the
/// project's other sidecars, the `FieldNoteStore` pattern. Deliberately NOT a
/// field on `CaptureProject` yet — this keeps experimental schema out of
/// `library.json` while the shape settles. Promotion to a manifest field (and
/// a `ProjectArchive.transferableSubfolders` ride-along) is a recorded
/// productization follow-up; until then overlays survive relaunches but do
/// not travel in `.lapse` archives or device transfers.
/// What the sidecar holds: the overlay list plus the mask dials that shape
/// how those overlays composite. The settings live here — not in editor
/// state — because the EXPORT needs them: a blend renders long after the
/// editor closed, and it must occlude with the same threshold/feather/bias
/// the preview was tuned with.
struct OverlayDocument: Codable, Equatable {
    var overlays: [SceneOverlay] = []
    var maskSettings: SegmentationSettings = SegmentationSettings()

    private enum CodingKeys: String, CodingKey {
        case overlays = "o", maskSettings = "m"
    }
}

extension AppModel {

    private static let overlaysFileName = "overlays.json"

    private func overlaysURL(for capture: CaptureProject) -> URL {
        projectFolderURL(for: capture).appendingPathComponent(Self.overlaysFileName)
    }

    /// The project's overlay document. Missing file = empty; a torn file
    /// reads as empty rather than crashing anything. Reads the spike's
    /// original bare-array format too, so early sidecars keep their text.
    func overlayDocument(for capture: CaptureProject) -> OverlayDocument {
        guard let data = try? Data(contentsOf: overlaysURL(for: capture)) else {
            return OverlayDocument()
        }
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(OverlayDocument.self, from: data) {
            return document
        }
        if let legacy = try? decoder.decode([SceneOverlay].self, from: data) {
            return OverlayDocument(overlays: legacy)
        }
        return OverlayDocument()
    }

    /// All overlays on a project.
    func overlays(for capture: CaptureProject) -> [SceneOverlay] {
        overlayDocument(for: capture).overlays
    }

    /// Writes the full document, removing the file when there are no
    /// overlays left — settings without an overlay describe nothing.
    func setOverlays(
        _ overlays: [SceneOverlay], maskSettings: SegmentationSettings,
        for capture: CaptureProject
    ) {
        let url = overlaysURL(for: capture)
        guard !overlays.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(
            OverlayDocument(overlays: overlays, maskSettings: maskSettings))
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Per-project overlay persistence: `overlays.json` beside the project's
/// other sidecars, the `FieldNoteStore` pattern, plus the `masks/` folder
/// holding any hand-supplied custom masks. Deliberately NOT a field on
/// `CaptureProject` — this keeps an experimental schema out of `library.json`
/// while the shape settles. Both the file and the folder are listed in
/// `ProjectArchive`, so overlays and their masks travel in `.lapse` archives
/// and device transfers.
///
/// What the sidecar holds: the layer list, the project's custom masks, and
/// the mask dials that shape how those layers composite. The settings live
/// here — not in editor state — because the EXPORT needs them: a blend
/// renders long after the editor closed, and it must occlude with the same
/// threshold/feather/bias the preview was tuned with.
struct OverlayDocument: Codable, Equatable {
    /// Front-to-back: index 0 is the frontmost layer.
    var overlays: [SceneOverlay] = []
    var maskSettings: SegmentationSettings = SegmentationSettings()
    /// Project-level custom masks. Masks belong to the project, not the
    /// layer — every text layer can pick any of them.
    var customMasks: [CustomMask] = []
    /// The project's drawn masks — Linear and Radial shapes, parameters only.
    /// Same standing as `customMasks`: they belong to the project, and both
    /// text placement and a `MaskGrade` can name any of them.
    var shapeMasks: [ShapeMask] = []
    /// The grades applied through those masks, in paint order — each one is
    /// composited after the whole-picture grade and before the text overlays.
    /// Unique on (mask, inverted); `addMaskGrade` is what keeps it so.
    var maskGrades: [MaskGrade] = []

    private enum CodingKeys: String, CodingKey {
        case overlays = "o", maskSettings = "m", customMasks = "cm",
             shapeMasks = "sm", maskGrades = "mg"
    }

    init() {}

    init(overlays: [SceneOverlay], maskSettings: SegmentationSettings,
         customMasks: [CustomMask], shapeMasks: [ShapeMask] = [],
         maskGrades: [MaskGrade] = []) {
        self.overlays = overlays
        self.maskSettings = maskSettings
        self.customMasks = customMasks
        self.shapeMasks = shapeMasks
        self.maskGrades = maskGrades
    }

    /// `customMasks` is younger than the file format, so its absence is
    /// normal rather than corrupt.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overlays = try c.decodeIfPresent([SceneOverlay].self, forKey: .overlays) ?? []
        maskSettings = try c.decodeIfPresent(
            SegmentationSettings.self, forKey: .maskSettings) ?? SegmentationSettings()
        customMasks = try c.decodeIfPresent([CustomMask].self, forKey: .customMasks) ?? []
        shapeMasks = try c.decodeIfPresent([ShapeMask].self, forKey: .shapeMasks) ?? []
        maskGrades = try c.decodeIfPresent([MaskGrade].self, forKey: .maskGrades) ?? []
        // A grade whose mask went away with an older build (or a hand-edited
        // sidecar) selects nothing and would sit in the card as a dead row.
        let live = Set(projectMasks.map(\.ref))
        maskGrades.removeAll { !live.contains($0.mask) }
    }

    /// The regions a layer can be placed into, in pill order. Sky and Land
    /// drop out once a custom mask claims "Replace Sky & Land" — that mask's
    /// own two names become the project's vocabulary.
    var placementRegions: [(placement: OverlayPlacement, label: String)] {
        var out: [(OverlayPlacement, String)] = []
        if !customMasks.contains(where: \.replacesSkyAndLand) {
            out.append((.sky, "Sky"))
            out.append((.land, "Land"))
        }
        for mask in customMasks {
            out.append((.custom(mask.id), mask.displayName))
            if !mask.invertedName.isEmpty {
                out.append((.customInverted(mask.id), mask.invertedName))
            }
        }
        // Drawn shapes are regions like any other: text placement gains them
        // for free, both ways round. A shape has no second name of its own,
        // so its complement is named from it.
        for mask in shapeMasks {
            out.append((.shape(mask.id), mask.displayName))
            out.append((.shapeInverted(mask.id), mask.invertedName))
        }
        return out
    }

    /// True when any layer asks for a region the segmentation model has to
    /// produce. Custom masks are files and drawn shapes are arithmetic, so
    /// neither ever needs the model.
    var needsSegmentationModel: Bool {
        let placed = overlays.contains { overlay in
            switch overlay.placement {
            case .sky, .land: return true
            case .none, .custom, .customInverted, .shape, .shapeInverted: return false
            }
        }
        // A grade applied inside Sky needs the mask just as much as a text
        // layer occluded by it does.
        return placed || needsSegmentationForGrades
    }

    /// True when the project has nothing to persist — no layers, no masks of
    /// either kind, and nothing graded through one. Settings alone describe
    /// nothing, but a project can legitimately hold a mask with the grade or
    /// the text not yet written.
    var isEmpty: Bool {
        overlays.isEmpty && customMasks.isEmpty && shapeMasks.isEmpty && maskGrades.isEmpty
    }
}

extension AppModel {

    private static let overlaysFileName = "overlays.json"
    /// Listed in `ProjectArchive.transferableSubfolders`.
    static let overlayMasksFolderName = "masks"

    private func overlaysURL(for capture: CaptureProject) -> URL {
        projectFolderURL(for: capture).appendingPathComponent(Self.overlaysFileName)
    }

    /// The project's custom-mask folder. Created on demand by the importer.
    func overlayMasksFolderURL(for capture: CaptureProject) -> URL {
        projectFolderURL(for: capture)
            .appendingPathComponent(Self.overlayMasksFolderName, isDirectory: true)
    }

    func customMaskURL(_ mask: CustomMask, for capture: CaptureProject) -> URL {
        overlayMasksFolderURL(for: capture).appendingPathComponent(mask.fileName)
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
            return OverlayDocument(
                overlays: legacy, maskSettings: SegmentationSettings(), customMasks: [],
                shapeMasks: [], maskGrades: [])
        }
        return OverlayDocument()
    }

    /// All overlays on a project.
    func overlays(for capture: CaptureProject) -> [SceneOverlay] {
        overlayDocument(for: capture).overlays
    }

    /// Writes the full document, removing the file when there is nothing
    /// left to describe — no layers AND no masks. Settings on their own
    /// describe nothing, but a project can legitimately hold masks with the
    /// text not yet written.
    func setOverlayDocument(_ document: OverlayDocument, for capture: CaptureProject) {
        let url = overlaysURL(for: capture)
        guard !document.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Copies a user-supplied black-and-white image into the project and
    /// returns the mask that names it. The file is copied, never referenced
    /// in place: the source may be a sandbox-scoped drop that is gone by the
    /// next launch, and the mask has to survive an archive round trip.
    func importCustomMask(
        from source: URL, name: String, for capture: CaptureProject
    ) throws -> CustomMask {
        let folder = overlayMasksFolderURL(for: capture)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        let id = UUID()
        // Normalized to PNG on the way in: the mask is read as a grayscale
        // grid, and a re-encode here means the render path never has to care
        // what the drop happened to be.
        let fileName = "\(id.uuidString).png"
        let destination = folder.appendingPathComponent(fileName)
        guard let image = Self.loadCGImage(from: source) else {
            throw NSError(
                domain: "OverlayStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "That file could not be read as an image."])
        }
        guard let out = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw NSError(
                domain: "OverlayStore", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not write the mask file."])
        }
        CGImageDestinationAddImage(out, image, nil)
        guard CGImageDestinationFinalize(out) else {
            throw NSError(
                domain: "OverlayStore", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not write the mask file."])
        }
        return CustomMask(
            id: id, name: name, invertedName: "",
            replacesSkyAndLand: false, fileName: fileName)
    }

    /// Deletes a custom mask's backing file. The caller drops it from the
    /// document; this only reclaims the disk.
    func deleteCustomMaskFile(_ mask: CustomMask, for capture: CaptureProject) {
        try? FileManager.default.removeItem(at: customMaskURL(mask, for: capture))
    }

    private static func loadCGImage(from url: URL) -> CGImage? {
        // A security-scoped drop needs the scope open for the read; a plain
        // file URL returns false here and is read anyway.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

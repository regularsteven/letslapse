import Foundation
import ImageIO
import LetsLapseKit

// MARK: - A photo's still, for a collection (D4, 2026-09-25)
//
// Steven: *any photo* can join a collection. A collection is made of blends
// (rule 4 of the brief — authored and rendered from blends alone, on any
// device that has them), so a single photo joins through a still blend of its
// own: its picture through its grade, at a collection's size, saved as a
// blend of its project. It travels like every blend (the blends queue, D1),
// a collection names it by id, and a device without the photo's original
// shows its still and fetches it when asked. Made only where the original is
// (a new blend needs the source — rule 1).

extension AppModel {

    /// The long edge a photo's still is written at — a 4K canvas with room
    /// for a gentle zoom (`StillClipMaker.maxLongEdge`).
    static let collectionStillLongEdge: CGFloat = 5120

    enum StillBlendError: LocalizedError {
        case originalNotHere
        case renderFailed
        var errorDescription: String? {
            switch self {
            case .originalNotHere: return "The photo isn't on this device — download it first."
            case .renderFailed: return "The photo couldn't be rendered as a still."
            }
        }
    }

    /// The blend that stands for a Photo capture in a collection: its stack
    /// when it has one (a JPEG burst's picture), else nil — the photo needs
    /// a still made (`makeStillBlend`).
    func collectionStill(for capture: CaptureProject) -> BlendProject? {
        guard capture.isPhotoCapture else { return nil }
        return blends(for: capture).first { $0.kind == .image }
    }

    /// Makes a photo's still: the picture through its grade (levelled,
    /// cropped, turned as the project shows it), a high-quality JPEG under
    /// `blends/`, registered in the project's document.
    func makeStillBlend(for capture: CaptureProject) async throws -> BlendProject {
        if let existing = collectionStill(for: capture) { return existing }
        guard capture.isPhotoCapture, let source = heroImageURL(for: capture),
              FileManager.default.fileExists(atPath: source.path) else { throw StillBlendError.originalNotHere }
        let preset = photoPreset(for: capture)
        let adjustments = photoAdjustments(for: capture)
        let white = whiteBalanceTrack(for: capture)
        let id = UUID()
        let fileName = "blends/\(id.uuidString).jpg"
        let destination = projectFolderURL(for: capture).appendingPathComponent(fileName)
        let rendered = try await Task.detached(priority: .userInitiated) { () -> (Int, Int) in
            guard let image = PhotoGrader.render(
                url: source, preset: preset, adjustments: adjustments, whiteBalance: white,
                maxDimension: Self.collectionStillLongEdge, cropped: true)
            else { throw StillBlendError.renderFailed }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ImageExporter.write(
                image, to: destination, format: .jpeg, quality: 0.93,
                metadata: ImageExporter.carryoverMetadata(from: source))
            return (image.width, image.height)
        }.value

        let grade = photoGrade(for: capture)
        var summary = "Still · \(rendered.0)×\(rendered.1)"
        if !grade.isColorIdentity { summary += " · \(grade.preset.displayName) grade baked in" }
        var blend = BlendProject(
            id: id, captureID: capture.id, kind: .image, createdAt: Date(),
            outputFileName: fileName, summary: summary,
            compressionRatio: 1, outputFPS: nil, linearLight: false, useRamp: false,
            rampStart: 0, rampEnd: 0, curve: "linear",
            width: rendered.0, height: rendered.1, inputFrames: 1, outputFrames: 1)
        let turns = capture.quarterTurns ?? 0
        blend.renderedQuarterTurns = turns == 0 ? nil : turns
        try store.update(capture.id) { document in
            document.blends.append(blend)
            document.capture.modifiedAt = Date()
            document.capture.modifiedBy = DeviceIdentity.id
        }
        noteFilesChanged(for: capture.id)
        if let fresh = self.capture(id: capture.id) { recordAssets(for: fresh, extractMetadata: false) }
        LLog("collections: made a still of \(capture.displayTitle) — \(rendered.0)×\(rendered.1)")
        return blend
    }
}

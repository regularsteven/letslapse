import CoreGraphics
import Foundation
import LetsLapseKit

/// The finished picture of a photo project as one image — the grade, the
/// grades applied through masks, the text and shape layers, then the level
/// and the crop: what the poster shows and what an export hands over
/// (2026-10-04). Until now the poster and the export carried the grade and
/// the geometry alone, so a text layer or a masked grade never reached the
/// Gallery, PicPlace's page or Photos — the editor was the only place that
/// drew them. Rendered from the originals' picture on a device that holds
/// it, or from the working copy on one that does not: the copy carries the
/// colour in its pixels, so it is drawn through the geometry alone.
///
/// The order is the editor's and the blend exporter's (`bakeExportFrameBody`):
/// grade → level with the overlays and masks (`bakeStill`, which levels the
/// base itself) → the crop cut last, in the levelled frame's unit square.
enum FinishedPicture {

    /// Everything the render needs, gathered on the main actor.
    struct Inputs: @unchecked Sendable {
        var source: URL
        var preset: PhotoPreset
        /// The full set, level and crop included.
        var adjustments: PhotoAdjustments
        var whiteBalance: WhiteBalanceTrack
        var overlays: [SceneOverlay]
        var maskGrades: [MaskGrade]
        var masks: SceneAwareCompositor.MaskSet
        var settings: SegmentationSettings
        /// The sky mask to take from the cache — or compute — when a layer or
        /// a masked grade sits in the sky or the land; nil when nothing does
        /// or no segmenter is installed (the composite then goes without
        /// occlusion, as the editor's preview does on a cache miss).
        var skyKey: String?

        /// Something beyond the grade and the geometry is drawn.
        var drawsAnything: Bool { !overlays.isEmpty || maskGrades.contains(where: \.isActive) }
    }

    /// The inputs for `capture` drawn from `source` through `grade` — the
    /// originals' picture with the project's grade, or the working copy
    /// through the geometry alone (`geometryOnly`).
    @MainActor
    static func inputs(for capture: AppModel.CaptureProject, source: URL, grade: PhotoGrade, in model: AppModel) -> Inputs {
        let document = model.overlayDocument(for: capture)
        var masks = SceneAwareCompositor.MaskSet()
        for mask in document.shapeMasks { masks.shapes[mask.id] = mask.shape }
        // Only the mask FILES something names — as the editor's preview set.
        var wanted = Set(document.overlays.compactMap { $0.placement.customMaskID })
        wanted.formUnion(document.maskGrades.filter(\.isActive).compactMap { $0.placement.customMaskID })
        for mask in document.customMasks where wanted.contains(mask.id) {
            masks.custom[mask.id] = CustomMaskLoader.mask(
                at: model.customMaskURL(mask, for: capture),
                turnedBy: model.customMaskTurns(mask, for: capture))
        }
        let wantsSky = document.overlays.contains { $0.placement == .sky || $0.placement == .land }
            || document.maskGrades.contains { $0.isActive && ($0.mask == .sky || $0.mask == .land) }
        let skyKey: String? = wantsSky
            ? CoreMLSceneSegmenter.locate().map {
                SceneMaskService.shared.frameKey(modelIdentity: $0.identity, url: source, presetID: grade.preset.presetID.uuidString)
            }
            : nil
        return Inputs(
            source: source, preset: grade.preset, adjustments: grade.adjustments, whiteBalance: grade.whiteBalance,
            overlays: document.overlays, maskGrades: document.maskGrades, masks: masks,
            settings: document.maskSettings, skyKey: skyKey)
    }

    /// The picture, off the main actor — nil when the source did not render.
    /// `maxDimension` bounds the long edge before the level and the crop
    /// (the poster's 1280); nil renders at the source's size (an export).
    static func render(_ inputs: Inputs, maxDimension: CGFloat?) async -> CGImage? {
        var masks = inputs.masks
        if let key = inputs.skyKey {
            // The model's reading of this frame, as the editor asks for it:
            // the graded frame at 512 px, uncropped. Cached per frame and
            // preset, so a second render costs nothing.
            let source = inputs.source
            let preset = inputs.preset
            var whole = inputs.adjustments
            whole.crop = nil
            masks.sky = try? await SceneMaskService.shared.skyMask(forKey: key) {
                PhotoGrader.render(url: source, preset: preset, adjustments: whole, maxDimension: 512, cropped: false)
            }
        }
        let resolved = masks
        let rotation = Double(inputs.adjustments.rotationDegrees)
        let finished = await MediaWorkQueue.shared.run { () -> CGImage? in
            // The grade alone, unlevelled and uncropped: `bakeStill` levels
            // the base with the overlays, and the crop is cut after them.
            guard let graded = PhotoGrader.render(
                url: inputs.source, preset: inputs.preset, adjustments: inputs.adjustments,
                rotationDegrees: 0, whiteBalance: inputs.whiteBalance, maxDimension: maxDimension, cropped: false)
            else { return nil }
            let baked = SceneAwareCompositor.bakeStill(
                graded, overlays: inputs.overlays, maskGrades: inputs.maskGrades,
                masks: resolved, settings: inputs.settings, rotationDegrees: rotation) ?? graded
            guard let crop = inputs.adjustments.crop else { return baked }
            return FrameCrop.apply(crop, to: baked)
        }
        return finished ?? nil
    }
}

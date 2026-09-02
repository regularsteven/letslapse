import CoreVideo
import Foundation
import LetsLapseKit

/// Everything a render job needs to bake a project's overlays into its
/// output, resolved BEFORE the job's detached work starts: the layer list,
/// the mask dials the preview was tuned with, and every mask those layers
/// name — the segmentation model's sequence mask (generated now if it isn't
/// cached) and any custom mask files, decoded once. The blend loop must
/// never wait on inference or a PNG decode mid-frame.
///
/// A value type crossing into the detached render task, so everything in it
/// is immutable and Sendable.
struct OverlayExportBake: Sendable {
    let overlays: [SceneOverlay]
    let masks: SceneAwareCompositor.MaskSet
    let settings: SegmentationSettings
    /// The project's grade, for its fine rotation — levelled into each OUTPUT
    /// frame before the overlays go on, at that frame's own moment when the
    /// level is keyframed. The one place a stills blend turns the picture:
    /// the stacker's frame hook is the only per-output-frame seam the Kit
    /// offers, which is why the geometry rides the overlay bake rather than
    /// a pass of its own; a project with a level and no text still gets one.
    var grade: PhotoGrade = .identity

    /// True when the frames have overlays to carry — as opposed to a bake
    /// that only levels them.
    var hasOverlays: Bool { !overlays.isEmpty }

    /// The level at one moment of the source.
    func rotation(at position: Double) -> Double {
        grade.rotationDegrees(at: position)
    }

    /// The layers as this moment's frame wants them. Layers are stored in the
    /// OPENING moment's levelled frame; when the level travels, every layer
    /// is re-expressed into this moment's frame so it stays pinned to the
    /// scene it was placed on (the editor shows exactly this). The frame's
    /// pixel size only needs the aspect, so 1×aspect is enough.
    func overlays(at position: Double) -> [SceneOverlay] {
        let opening = grade.rotationDegrees
        let now = rotation(at: position)
        guard opening != now, let aspect = frameAspect else { return overlays }
        return overlays.map { $0.remapped(fromRotation: opening, to: now, width: aspect, height: 1) }
    }

    /// The source frame's aspect (w ÷ h), needed only to remap layers between
    /// moments of a travelling level.
    var frameAspect: Double?

    /// The closure `ImageStacker`'s `overlayComposite` hook wants.
    func stackerHook() -> (CVPixelBuffer, Double, CVPixelBufferPool) throws -> CVPixelBuffer? {
        { buffer, position, pool in
            try SceneAwareCompositor.bakeExportFrame(
                buffer, position: position, pool: pool,
                overlays: overlays(at: position), masks: masks, settings: settings,
                rotationDegrees: rotation(at: position))
        }
    }
}

extension AppModel {
    /// The overlay bake for one capture's render, or nil when the project
    /// has no text to bake. Mirrors the editor preview's degradation rule
    /// exactly: with a placement chosen and the segmentation model
    /// installed, the sequence mask is fetched (cache-first, generating on
    /// a cold cache — a few seconds, before the render starts); without the
    /// model, or if segmentation fails, the text bakes as a plain overlay —
    /// the same thing the preview shows in that state. Custom masks are
    /// files, so they resolve whether or not the model is installed.
    func makeOverlayExportBake(for capture: CaptureProject?) async -> OverlayExportBake? {
        guard let capture else { return nil }
        let document = overlayDocument(for: capture)
        let grade = photoGrade(for: capture)
        let aspect: Double? = {
            guard let width = capture.sourceWidth, let height = capture.sourceHeight,
                  width > 0, height > 0 else { return nil }
            return Double(width) / Double(height)
        }()
        // Hidden layers are not part of the piece; onion skin is an editor
        // affordance and never reaches an export.
        let overlays = document.overlays.filter { !$0.text.isEmpty && $0.isVisible }
        guard !overlays.isEmpty else {
            // Nothing to draw — but a levelled project still needs the hook,
            // which is where the level is baked.
            guard grade.hasRotation else { return nil }
            return OverlayExportBake(
                overlays: [], masks: SceneAwareCompositor.MaskSet(),
                settings: document.maskSettings, grade: grade, frameAspect: aspect)
        }

        var masks = SceneAwareCompositor.MaskSet()

        // Custom masks first — cheap, and they may be all the project needs.
        for mask in document.customMasks
        where overlays.contains(where: { $0.placement.customMaskID == mask.id }) {
            if let loaded = CustomMaskLoader.mask(at: customMaskURL(mask, for: capture)) {
                masks.custom[mask.id] = loaded
            } else {
                LLog("overlay bake: custom mask \(mask.displayName) unreadable — baking that layer without occlusion")
            }
        }

        let needsModel = overlays.contains { placement in
            switch placement.placement {
            case .sky, .land: return true
            case .none, .custom, .customInverted: return false
            }
        }
        if needsModel, let source = CoreMLSceneSegmenter.locate() {
            // The same inputs the editor's fetch uses, so a mask the editor
            // already computed is a cache hit here — and one this render
            // generates is a cache hit for the editor afterwards.
            let preset = photoPreset(for: capture)
            let adjustments = photoAdjustments(for: capture)
            let frames = visibleFrameURLs(for: capture)
            let key = SceneMaskService.shared.sequenceKey(
                modelIdentity: source.identity, frames: frames,
                presetID: preset.presetID.uuidString, sampleCount: SceneMaskService.sequenceSampleCount)
            do {
                masks.sky = try await SceneMaskService.shared.sequenceSkyMask(
                    forKey: key, modelIdentity: source.identity, frames: frames,
                    sampleCount: SceneMaskService.sequenceSampleCount, presetID: preset.presetID.uuidString
                ) { url in
                    PhotoGrader.render(
                        url: url, preset: preset, adjustments: adjustments, maxDimension: 512)
                }
            } catch {
                LLog("overlay bake: segmentation unavailable (\(error.localizedDescription)) — baking text without occlusion")
            }
        }
        return OverlayExportBake(
            overlays: overlays, masks: masks, settings: document.maskSettings,
            grade: grade, frameAspect: aspect)
    }
}

import CoreVideo
import Foundation
import LetsLapseKit

/// Everything a render job needs to bake a project's overlays into its
/// output, resolved BEFORE the job's detached work starts: the overlay
/// list, the mask dials the preview was tuned with, and the sequence mask
/// itself — generated now if it isn't cached, because the blend loop must
/// never wait on (or trigger) inference mid-frame.
///
/// A value type crossing into the detached render task, so everything in it
/// is immutable and Sendable.
struct OverlayExportBake: Sendable {
    let overlays: [SceneOverlay]
    let skyMask: SceneMask?
    let settings: SegmentationSettings

    /// The closure `ImageStacker`'s `overlayComposite` hook wants.
    func stackerHook() -> (CVPixelBuffer, Double, CVPixelBufferPool) throws -> CVPixelBuffer? {
        { buffer, position, pool in
            try SceneAwareCompositor.bakeExportFrame(
                buffer, position: position, pool: pool,
                overlays: overlays, skyMask: skyMask, settings: settings)
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
    /// the same thing the preview shows in that state.
    func makeOverlayExportBake(for capture: CaptureProject?) async -> OverlayExportBake? {
        guard let capture else { return nil }
        let document = overlayDocument(for: capture)
        let overlays = document.overlays.filter { !$0.text.isEmpty }
        guard !overlays.isEmpty else { return nil }

        var skyMask: SceneMask?
        if overlays.contains(where: { $0.placement != .none }),
           let source = CoreMLSceneSegmenter.locate() {
            // The same inputs the editor's fetch uses, so a mask the editor
            // already computed is a cache hit here — and one this render
            // generates is a cache hit for the editor afterwards.
            let preset = photoPreset(for: capture)
            let adjustments = photoAdjustments(for: capture)
            let frames = visibleFrameURLs(for: capture)
            let key = SceneMaskService.shared.sequenceKey(
                modelIdentity: source.identity, frames: frames,
                presetID: preset.presetID.uuidString, sampleCount: 9)
            do {
                skyMask = try await SceneMaskService.shared.sequenceSkyMask(
                    forKey: key, modelIdentity: source.identity, frames: frames,
                    sampleCount: 9, presetID: preset.presetID.uuidString
                ) { url in
                    PhotoGrader.render(
                        url: url, preset: preset, adjustments: adjustments, maxDimension: 512)
                }
            } catch {
                LLog("overlay bake: segmentation unavailable (\(error.localizedDescription)) — baking text without occlusion")
            }
        }
        return OverlayExportBake(
            overlays: overlays, skyMask: skyMask, settings: document.maskSettings)
    }
}

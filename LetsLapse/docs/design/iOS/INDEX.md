# iOS (iPhone) design specs

Canvas 393×852 pt (iPhone 16/17 class). One file per screen per orientation; variants in the filename. Status: ✅ Synced · ⚠️ Stale · 🟡 Planned (not yet drawn).

Last full sync: 2026-07-31, working tree of `ios-app` (uncommitted WIP included) — adding burst slow-motion ramps: a Video section in Settings and a Slow-motion ramp row in New version, above Advanced. Project detail carries no ramp UI.

## Tabs

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Create (tab home) | [create-home.portrait.svg](create-home.portrait.svg) | `App/CreateView.swift` | ✅ |
| Gallery | [gallery.portrait.svg](gallery.portrait.svg) | `App/GalleryView.swift` + `App/CaptureFilterBar.swift` + `App/CapturePhotoGrid.swift` (`CaptureAssetGrid`) | ✅ |
| Projects | [projects.portrait.svg](projects.portrait.svg) | `App/ProjectsView.swift` (`header`, `ProjectCard`) + `App/CaptureFilterBar.swift` | ✅ |
| Projects · filter matched nothing | — | `App/ProjectsView.swift` (`filteredEmptyState`) — "No videos" + Show all, in place of the card list | 🟡 |
| Settings | [settings.portrait.svg](settings.portrait.svg) | `App/SettingsView.swift` (`creativeDefaultsCard`, `burstRampCard`, `recordingCard`, `locationCard`, `storageCard`) | ✅ |

Note: on iOS, selecting the Create tab opens the camera immediately; Create home is the surface behind/under the camera, revealed on close.

Note: two different screens are called a "viewer" and are easy to confuse. `project-photos.viewer.*` (plural) is the interval-frame pager — swipe through a shoot's source frames, save one to Photos. `project-photo.viewer.*` (singular) is the grading viewer — presets, sliders, white balance — opened for a Photo-mode capture or an interval shoot's first frame. They share no code.

Note: grading is a property of every project, not just Photo mode. `GradingCard` (the graded preview + preset strip) tops all three project-detail variants, so a change to it makes all three stale. Photo and interval open `PhotoViewerView` from the card; video customises in the card itself, through the same `PhotoAdjustmentsPanel` the viewer uses.

Shared components: `CaptureFilterBar` (the All · Photos · Interval · Video segmented control) and `CaptureAssetGrid` / `CaptureAssetTile` (the square thumbnail grid) are used by more than one screen, so their geometry is specified once in [gallery.portrait.svg](gallery.portrait.svg) and reused verbatim in [projects.portrait.svg](projects.portrait.svg) and [project-photos.portrait.svg](project-photos.portrait.svg). A change to either component makes all three stale. Both tabs share the same top rhythm: 15pt above the title, 8pt above and below the filter bar, content flush after it.

## Capture (full-screen camera, always dark)

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Photo · idle | [capture-photo.portrait.svg](capture-photo.portrait.svg) | `App/CaptureView.swift` (`portraitLayout`, `photoControlsRow`) | ✅ |
| Interval · idle | [capture-interval.portrait.svg](capture-interval.portrait.svg) | `App/CaptureView.swift` (`intervalPickerRow`) | ✅ |
| Interval · running | [capture-interval.running.portrait.svg](capture-interval.running.portrait.svg) | `App/CaptureView.swift` (`intervalRunningPills`, `blendDiagnosticsReadout`) | ✅ |
| Video · idle | [capture-video.portrait.svg](capture-video.portrait.svg) | `App/CaptureView.swift` (`speedChipsRow`) | ✅ |
| Video · recording | [capture-video.recording.portrait.svg](capture-video.recording.portrait.svg) | `App/CaptureView.swift` (`speedMarquee`, `segmentStrip`) | ✅ |
| Interval · idle · landscape | [capture-interval.landscape.svg](capture-interval.landscape.svg) | `App/CaptureView.swift` (`landscapeLayout`, `landscapeExposureControl`) | ✅ |
| Video · idle · landscape | [capture-video.landscape.svg](capture-video.landscape.svg) | `App/CaptureView.swift` (`landscapeLayout`, `landscapeEstimateChips`, `landscapeExposureControl`) | ✅ |
| Exposure locked · brightness + focus sliders | [capture-exposure-locked.portrait.svg](capture-exposure-locked.portrait.svg) | `App/CaptureView.swift` (`exposurePanel`) — brightness is a ±3 EV offset centered on the locked exposure, not absolute ISO | ✅ |
| Photo · burst counter / steady gate / DNG overlay | — | `App/CaptureView.swift` (`SteadyGateOverlay`, viewfinder overlays) | 🟡 |
| Photo · idle · landscape | — | same rails as interval landscape, BLEND-only corner overlay | 🟡 |
| Camera-denied overlay | — | `App/CaptureView.swift` (`authorizationMessage`) | 🟡 |
| Psycho blending notice (alert) | — | `App/CaptureView.swift` (`showPsychoNotice`) | 🟡 |

## Capture sheets

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Capture format | [capture-format-sheet.portrait.svg](capture-format-sheet.portrait.svg) | `App/CaptureView.swift` (`FormatSheet`) | ✅ |
| Capture for a target | [capture-target-sheet.portrait.svg](capture-target-sheet.portrait.svg) | `App/CaptureView.swift` (`CaptureTargetSheet`) | ✅ |

## Projects & flow

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Project detail (video) | [project-detail.video.portrait.svg](project-detail.video.portrait.svg) | `App/ProjectDetailView.swift` (`GradingCard` incl. `customiseControls`, `sourceClipsSection`, `versionRow`, `managementCard`) | ✅ |
| Project detail (interval) | [project-detail.interval.portrait.svg](project-detail.interval.portrait.svg) | `App/ProjectDetailView.swift` (`GradingCard`, `originalsSection` — Save all to Photos + View all photos) | ✅ |
| Project detail (photo) | [project-detail.photo.portrait.svg](project-detail.photo.portrait.svg) | `App/ProjectDetailView.swift` (`GradingCard`, `photoActions`) | ✅ |
| Project detail (video) · Customise expanded | — | `App/ProjectDetailView.swift` (`GradingCard.customiseControls` inline panel, and its ≥500pt sheet branch) — panel geometry is specified by [project-photo.viewer.expanded.portrait.svg](project-photo.viewer.expanded.portrait.svg) (same `PhotoAdjustmentsPanel`) | 🟡 |
| Photo grading viewer · Customise collapsed | [project-photo.viewer.portrait.svg](project-photo.viewer.portrait.svg) | `App/PhotoViewerView.swift` (stacked layout, `presetStrip`, `customiseDisclosure`) | ✅ |
| Photo grading viewer · Customise expanded | [project-photo.viewer.expanded.portrait.svg](project-photo.viewer.expanded.portrait.svg) | `App/PhotoViewerView.swift` (`PhotoAdjustmentsPanel`, shared with the video card) | ✅ |
| Photo grading viewer · side rail | [project-photo.viewer.landscape.svg](project-photo.viewer.landscape.svg) | `App/PhotoViewerView.swift` (wide branch, ≥500pt available width — iPhone landscape, the iPad sheet, a widened Mac window) | ✅ |
| Photo grading viewer · Save as preset (alert) | — | `App/PhotoViewerView.swift` (`isNamingPreset` — TextField alert) | 🟡 |
| Project photos (interval frames, sheet) | [project-photos.portrait.svg](project-photos.portrait.svg) | `App/CapturePhotoGrid.swift` (`CapturePhotoGrid`, `CaptureAssetGrid`, `CaptureAssetTile`) | ✅ |
| Project photos · fullscreen viewer | [project-photos.viewer.portrait.svg](project-photos.viewer.portrait.svg) | `App/CapturePhotoGrid.swift` (`CaptureFrameViewer`) + `App/ProjectMedia.swift` (`ProjectPreviewImage`) | ✅ |
| Adjust (video source) | [adjust.portrait.svg](adjust.portrait.svg) | `App/AdjustView.swift` (`sourceCard`, `blendFromSection`, `speedSection`, `estimateCard`, `burstRampRow`, `advancedRow`) | ✅ |
| Adjust (photos source) | [adjust.photos.portrait.svg](adjust.photos.portrait.svg) | `App/AdjustView.swift` (`stackCard`, `TailFrameBanner`) | ✅ |
| Processing | [processing.portrait.svg](processing.portrait.svg) | `App/ProcessingView.swift` | ✅ |
| Result | [result.portrait.svg](result.portrait.svg) | `App/ResultView.swift` | ✅ |
| Advanced options (sheet) | — | `App/AdjustView.swift` (`AdvancedOptionsSheet`) | 🟡 |
| Custom speed (sheet) | — | `App/AdjustView.swift` (`CustomSpeedSheet`) | 🟡 |
| Media preview (sheet) | — | `App/ProjectMedia.swift` (`ProjectMediaPreviewSheet`) | 🟡 |
| Manage clip encodings (sheet) | — | `App/ProjectDetailView.swift` (`ManageClipSheet`) | 🟡 |

## Settings sub-screens

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Manage resolutions | [manage-resolutions.portrait.svg](manage-resolutions.portrait.svg) | `App/ManageResolutionsView.swift` | ✅ |
| Large originals | — | `App/SettingsView.swift` (`LargeOriginalsView`) | 🟡 |
| Performance | — | `App/SettingsView.swift` (`PerformanceSettingsView`) | 🟡 |
| Blend learning | — | `App/SettingsView.swift` (`BlendLearningView`) | 🟡 |
| Diagnostics | — | `App/SettingsView.swift` (`DiagnosticsView`) | 🟡 |
| Capture benchmark (sheet) | — | `App/CaptureBenchmark.swift` | 🟡 |

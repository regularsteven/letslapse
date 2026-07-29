# iOS (iPhone) design specs

Canvas 393×852 pt (iPhone 16/17 class). One file per screen per orientation; variants in the filename. Status: ✅ Synced · ⚠️ Stale · 🟡 Planned (not yet drawn).

Last full sync: 2026-07-29, working tree of `ios-app` (uncommitted WIP included).

## Tabs

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Create (tab home) | [create-home.portrait.svg](create-home.portrait.svg) | `App/CreateView.swift` | ✅ |
| Gallery | [gallery.portrait.svg](gallery.portrait.svg) | `App/GalleryView.swift` | ✅ |
| Projects | [projects.portrait.svg](projects.portrait.svg) | `App/ProjectsView.swift` | ✅ |
| Settings | [settings.portrait.svg](settings.portrait.svg) | `App/SettingsView.swift` | ✅ |

Note: on iOS, selecting the Create tab opens the camera immediately; Create home is the surface behind/under the camera, revealed on close.

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
| Project detail (video/interval) | [project-detail.portrait.svg](project-detail.portrait.svg) | `App/ProjectDetailView.swift` | ✅ |
| Project detail (photo) | [project-detail.photo.portrait.svg](project-detail.photo.portrait.svg) | `App/ProjectDetailView.swift` (`PhotoGradingCard`, `photoActions`) | ✅ |
| Adjust (video source) | [adjust.portrait.svg](adjust.portrait.svg) | `App/AdjustView.swift` | ✅ |
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

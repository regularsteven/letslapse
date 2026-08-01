# iOS (iPhone) design specs

Canvas 393×852 pt (iPhone 16/17 class). One file per screen per orientation; variants in the filename. Status: ✅ Synced · ⚠️ Stale · 🟡 Planned (not yet drawn).

Last full sync: 2026-08-01, working tree of `ios-app` — vocabulary rename: user-facing **"version" → "blended clip"** everywhere (project detail rows/headers/alerts, projects cards, adjust/processing/result flow, settings storage + large originals), and the fifth tab swapped: Music (spike, now parked) → **Collections** placeholder ([collections.portrait.svg](collections.portrait.svg)). Previous sync (2026-07-31) was the playback unification: one fullscreen player ([player.portrait.svg](player.portrait.svg)) behind every playback tap on project detail, whole-row tap targets on clip and blended-clip rows, an interval card that leads with Play and keeps "Edit photo" as a second affordance, and a Burst frames card on a blended Photo shot.

## Tabs

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Create (tab home) | [create-home.portrait.svg](create-home.portrait.svg) | `App/CreateView.swift` | ✅ |
| Gallery | [gallery.portrait.svg](gallery.portrait.svg) | `App/GalleryView.swift` + `App/CaptureFilterBar.swift` + `App/CapturePhotoGrid.swift` (`CaptureAssetGrid`) | ✅ |
| Projects | [projects.portrait.svg](projects.portrait.svg) | `App/ProjectsView.swift` (`header`, `ProjectCard`) + `App/CaptureFilterBar.swift` | ✅ |
| Projects · filter matched nothing | — | `App/ProjectsView.swift` (`filteredEmptyState`) — "No videos" + Show all, in place of the card list | 🟡 |
| Collections (placeholder) | [collections.portrait.svg](collections.portrait.svg) | `App/CollectionsView.swift` (`header`, `comingSoonCard`) | ✅ |
| Settings | [settings.portrait.svg](settings.portrait.svg) | `App/SettingsView.swift` (`creativeDefaultsCard`, `burstRampCard`, `recordingCard`, `locationCard`, `storageCard`) | ✅ |

Note: on iOS, selecting the Create tab opens the camera immediately; Create home is the surface behind/under the camera, revealed on close.

Note: **Collections is a placeholder** (2026-08-01) — the tab exists so the slot isn't a dead end while the real Collections UX (gather blended clips from projects into an arrangeable timeline, export as one video) is out for design; see the repo-root `docs/letslapse-collections-ux-brief.md`. It took the slot of the **Music spike, now parked**: `App/MusicView.swift` and `MusicBedEngine` stay in the codebase and compiling, but no tab routes to them. [music.portrait.svg](music.portrait.svg) is kept unchanged as the spec of the parked screen (its drawn tab bar still shows the old Music tab — historical); expect the soundtrack idea to resurface inside Collections.

Note: the floating tab bar is a shared component drawn in every tab-level screen here, so **any change to `LLTab` restages all of them**. It now carries five tabs (Create · Gallery · Projects · Collections · Settings) at 66pt each — down from 92pt, because five 92pt tabs would make a 488pt pill on a 393pt screen. Bar: 358×57 at x 17.5, tab centres 56.5 / 126.5 / 196.5 / 266.5 / 336.5.

Note: two different screens are called a "viewer" and are easy to confuse. `project-photos.viewer.*` (plural) is the interval-frame pager — swipe through a shoot's source frames, save one to Photos. `project-photo.viewer.*` (singular) is the grading viewer — presets, sliders, white balance — opened for a Photo-mode capture or an interval shoot's first frame. They share no code.

Note: grading is a property of every project, not just Photo mode. `GradingCard` (the graded preview + preset strip) tops all three project-detail variants, so a change to it makes all three stale. Photo and interval open `PhotoViewerView` from the card; video customises in the card itself, through the same `PhotoAdjustmentsPanel` the viewer uses.

Note: a third fullscreen surface exists — `FullscreenMediaSheet` (`App/FullscreenMediaSheet.swift`), the in-app **player**, drawn in [player.portrait.svg](player.portrait.svg). Project detail routes every playback tap into it (hero play button, source clip rows, blended-clip rows, and an interval shoot's motion preview); it is black, edge to edge, close top-left, share top-right, pages left/right through the tapped item's siblings and down to dismiss. It is not the grading editor and not the frame pager — a still opens the editor only when the caller hands it a capture id, which blended clips deliberately don't.

Shared components: `CaptureFilterBar` (the All · Photos · Interval · Video segmented control) and `CaptureAssetGrid` / `CaptureAssetTile` (the square thumbnail grid) are used by more than one screen, so their geometry is specified once in [gallery.portrait.svg](gallery.portrait.svg) and reused verbatim in [projects.portrait.svg](projects.portrait.svg) and [project-photos.portrait.svg](project-photos.portrait.svg). A change to either component makes all three stale. Both tabs share the same top rhythm: 15pt above the title, 8pt above and below the filter bar, content flush after it.

## Capture (full-screen camera, always dark)

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Photo · idle | [capture-photo.portrait.svg](capture-photo.portrait.svg) | `App/CaptureView.swift` (`portraitLayout`, `photoControlsRow`) | ✅ |
| Interval · idle | [capture-interval.portrait.svg](capture-interval.portrait.svg) | `App/CaptureView.swift` (`intervalPickerRow`) | ✅ |
| Interval · running | [capture-interval.running.portrait.svg](capture-interval.running.portrait.svg) | `App/CaptureView.swift` (`intervalRunningPills` — `BurstStatusIndicator` zebra + elapsed pill, `blendDiagnosticsReadout`); same row for JPEG and DNG runs | ✅ |
| Video · idle | [capture-video.portrait.svg](capture-video.portrait.svg) | `App/CaptureView.swift` (`speedChipsRow`) | ✅ |
| Video · recording | [capture-video.recording.portrait.svg](capture-video.recording.portrait.svg) | `App/CaptureView.swift` (`speedMarquee`, `segmentStrip`) | ✅ |
| Interval · idle · landscape | [capture-interval.landscape.svg](capture-interval.landscape.svg) | `App/CaptureView.swift` (`landscapeLayout`, `landscapeExposureControl`) | ✅ |
| Video · idle · landscape | [capture-video.landscape.svg](capture-video.landscape.svg) | `App/CaptureView.swift` (`landscapeLayout`, `landscapeEstimateChips`, `landscapeExposureControl`) | ✅ |
| Exposure locked · brightness + focus sliders | [capture-exposure-locked.portrait.svg](capture-exposure-locked.portrait.svg) | `App/CaptureView.swift` (`exposurePanel`) — brightness is a ±3 EV offset centered on the locked exposure, not absolute ISO | ✅ |
| Photo · burst running | [capture-photo.burst.portrait.svg](capture-photo.burst.portrait.svg) | `App/CaptureView.swift` (`burstStatusPill`) + `App/BurstStatusIndicator.swift` — drawn capped (7/10 fill); the Bulb twin is the same pill with a decay zebra + bare count, seeded via `LL_BURST`. Covers JPEG and DNG shots (DNG counts RAW frames in the window; the "Blending DNG…" text is gone) | ✅ |
| Photo · steady gate | — | `App/CaptureView.swift` (`SteadyGateOverlay`) | 🟡 |
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
| Project detail (video) | [project-detail.video.portrait.svg](project-detail.video.portrait.svg) | `App/ProjectDetailView.swift` (`GradingCard` incl. `customiseControls`, `sourceClipsSection`, `versionRow` — whole row taps to play, `managementCard`) | ✅ |
| Project detail (interval) | [project-detail.interval.portrait.svg](project-detail.interval.portrait.svg) | `App/ProjectDetailView.swift` (`GradingCard` with both affordances — `heroButton` play + the Edit photo pill, `originalsSection` — Save all to Photos + View all photos) | ✅ |
| Project detail (photo) | [project-detail.photo.portrait.svg](project-detail.photo.portrait.svg) | `App/ProjectDetailView.swift` (`GradingCard`, `photoActions`, and — for a blended shot only — `originalsSection` in its "Burst frames" wording) | ✅ |
| Fullscreen media player (video) | [player.portrait.svg](player.portrait.svg) | `App/FullscreenMediaSheet.swift` (`FullscreenMediaSheet` chrome + `FullscreenVideoPage` scrubber) — the one in-app player: source clips, blended clips, the hero's play button | ✅ |
| Fullscreen media player · interval motion | — | `App/FullscreenMediaSheet.swift` (`FrameSequencePage`) — same chrome, transport row instead of a scrubber: play/pause · "12 / 184" · "12 fps preview" | 🟡 |
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

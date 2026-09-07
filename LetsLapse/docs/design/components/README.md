# Design components

Shared pieces of chrome that several screen mirrors draw identically. A screen SVG **references** a component instead of redrawing it, so a change to the piece is one edit here rather than twenty edits across the platform folders. Introduced 2026-09-04 with the shutter cluster, which nineteen iOS mirrors and two macOS mirrors had each been drawing by hand.

## How a screen references a component

```xml
<image id="shutter-cluster" href="../components/shutter-cluster.idle.portrait.svg" x="106.5" y="708" width="180" height="100"/>
```

- Paths are relative to the platform folder (`iOS/`, `macOS/`), so they always read `../components/…`.
- One file per component **state and orientation**, named `<component>.<state>.<orientation>.svg` like the screens; both are chosen by filename. A single file with several ids would need `<use href="file.svg#id">`, which Quick Look does not follow across files (tested 2026-09-04), so it is not used.
- Keep a comment beside the reference saying which file to edit and how the placement was computed.

## Where it renders

| Viewer | External `<image>` | Notes |
|---|---|---|
| Finder / Quick Look | ✅ | The everyday viewer. From a shell: `qlmanage -t -s 1200 -o <dir> <file.svg>`. |
| Browser, file opened directly or via `<object>` | ✅ | Chromium and WebKit, tested 2026-09-04. |
| Browser, SVG inside `<img>` — GitHub's file view, Markdown image embeds | ❌ | Browsers never load external resources for an SVG shown as an image; the component's box renders empty. Open the raw file, or the component file itself. |
| `rsvg-convert` (librsvg) | ❌ for `../` paths | librsvg only follows references into the file's own directory or below. Render screen mirrors with Quick Look or a browser; `rsvg-convert` still renders the component files on their own. |
| VS Code | untested | Depends on the preview extension. |

## Shutter cluster — `shutter-cluster.<state>.<orientation>.svg`

The capture screen's record/stop button with its four framing slots, drawn once for every mode and both orientations.

**Coordinate contract.** 1 unit = 1 pt, origin at the **centre of the ring**. The two orientations differ only in where the four slots sit, so each has its own box:

| Orientation | Slot offsets | viewBox | Place with |
|---|---|---|---|
| portrait | (±66, ±26) | `-90 -50 180 100` | `x = cx − 90`, `y = cy − 50`, `width="180" height="100"` |
| landscape | (±56, ±36) | `-80 -60 160 120` | `x = cx − 80`, `y = cy − 60`, `width="160" height="120"` |

(cx, cy) is the ring centre on that screen. The Mac uses the landscape set: its capture sheet is the landscape tree.

**Geometry.** Ring r 38 (4 pt white stroke) around a 60 pt red disc (idle) or a 32 pt rounded stop square (running). Four 44 pt graphite circles. Portrait keeps them ≈9 pt clear of the ring, pulled in from the ≈32 pt gap the 2026-08 mirrors had. Landscape (2026-09-04, Steven) brings each side a further 10 pt in and each row 10 pt out, so the cluster is narrower and uses the rail's height: ≈4.6 pt clear of the ring. Widen the rows to ±44 if that ever feels tight.

**Slots** — the viewer's frame, identical in both orientations:

| Slot | Position | Occupant | SF Symbol | On treatment |
|---|---|---|---|---|
| 1 | top-left | Grid | `grid.circle` / `.fill` | amber glyph |
| 2 | top-right | 2 s delay | `timer` | amber glyph; "2s" badge on the disc |
| 3 | bottom-left | AE/AF lock | `lock.open` / `lock.fill` | black padlock on an amber disc |
| 4 | bottom-right | Capture when steady | `hand.raised` / `.fill` | amber glyph; hand badge on the disc |

The padlock is the lock's glyph in **every** mode. Under Interval's Dynamic and Ladder modes the button locks focus only (the ramp owns exposure) but no longer changes its glyph to say so — decision 2026-09-04; the earlier mirrors drew `camera.metering.center.weighted` there.

**Where the ring sits.** Pinned to the phone: 94 pt in from the home-indicator edge, on the screen's centreline, in every orientation.

- iOS portrait (393×852): ring (196.5, 758) → image x 106.5, y 708.
- iOS landscape, notch left (852×393): ring (758, 196.5) → image x 678, y 136.5 (landscape set). Notch right mirrors it to the left edge; upside-down portrait puts it at the top. Neither is drawn.
- macOS capture sheet (960×720 at 20,20): no device edge to pin to. The landscape cluster is fitted 8 pt inside the sheet's right edge at mid-height, where the rail's spacers put the ring: ring (894, 380) → image x 814, y 320. It overhangs the viewfinder column by 46 pt.

**Rotation.** The ring never moves: the interface reflows but the cluster's centre stays on the same physical spot. The four circles do **not** keep their physical spots across a turn — the wide portrait 2×2 becomes the narrower, taller landscape 2×2 around the same ring. Steven chose this on 2026-09-04 over a diamond that would have kept them fixed, because the diamond wasted the rail's height in landscape and needed the portrait mode row moved up. Glyphs stay upright in the viewer's frame; slot numbering (1/2 top, 3/4 bottom) is the viewer's frame in both orientations. **Notch-right landscape is the mirror image**: the ring pins to the left edge and the two rails swap sides with it — the chrome rail (close, pills, tile) moves to the trailing edge with its pills trailing-anchored — the way the system camera's do; not drawn. iPhones never rotate to upside-down portrait; on an iPad that pins the ring to the top edge.

**Run-time toggles (2026-09-04, third pass).** Once a shoot is under way the top pair holds two toggles in every Interval and Video run: **slot 1 Dim** (`moon` / `moon.fill`, amber while engaged) and **slot 2 Info** (`info.circle` / `.fill`, amber when on). Dim: pressing on floors the screen at once; a touch on the dimmed screen wakes it for 30 s and it re-dims by itself unless the toggle is turned off in that window; Settings' "Dim screen during shoot" seeds the toggle at run start (on by default, so the running mirrors show the amber moon — they are the wake window). Info: off by default, per run; on, Interval shows the ONE diagnostics panel (frames in the window · last · output cadence · blend cost, format, health and thermal state) and Video shows the speed → playback-seconds marquee. The readout under a running Interval is otherwise only the amber line — current shutter · ISO · scene EV, plus the ramp's status when it has one — and the ±EV bias slider; the ramp readout panel and the output-count / elapsed pills row are gone. The Mac has no dimmer, so its running cluster carries Info alone (`running.mac`). Scanner runs are unchanged, and a Photo burst keeps its slots empty (seconds long, nothing to dim or explain).

**States** — one file each, per orientation (seventeen files):

| File | Shows | Used by |
|---|---|---|
| `idle` | red disc, four toggles off | every idle capture mirror |
| `armed` | every toggle on plus both badges — the ON reference | no screen directly |
| `locked` | AE/AF held, the others off | `capture-exposure-locked` |
| `running` | stop square; slot 1 Dim (engaged), slot 2 Info (off); bottom pair empty | Interval runs, Photo bursts |
| `running.info` | as `running` with Info on | `capture-interval.running.info` |
| `running.mac` | landscape only: stop square, Info in slot 2, no Dim (iOS-only) | the macOS running mirror |
| `running.video` | stop square; slot 1 Dim, slot 2 Info (off); slot 3 the speed-burst / marker trigger, slot 4 the burst count | `capture-video.recording.*` |
| `running.video.info` | as `running.video` with Info on (the marquee shows) | `capture-video.recording.info` |
| `running.scanner` | stop square in a poses-banked ring; slot 4 the manual pose shutter | `capture-interval.scanner*` |

Once a shoot starts the four framing toggles hide in every mode (decision 2026-09-04); the slots stay reserved, so the footprint never changes. Code mirrored the same day: `clusterSlot` in `App/CaptureView.swift` keys on `isCapturing`, not only a movie recording. The run-time Dim / Info toggles (third pass) were mirrored the same day: `dimToggleCircle` / `runInfoToggleCircle`, `seedRunToggles`, the run readout (`runExposureLine`, `runInfoPanel`, `runReadoutCapsule`) in `App/CaptureView.swift`; hooks `LL_RUNINFO=1` and `LL_RUNDIM=off|wake` stage them.

**Mirrors.** `App/CaptureView.swift`: `shutterClusterLayer` (the pin, over both layouts' chrome) → `shutterClusterPin` (94 pt from the home-indicator edge, via the scene's interface orientation) → `shutterCluster` → `clusterSlot` (what each slot holds per state) → `shutterButton`, `shutterBadge`, `gridToggleCircle`, `shutterDelayCircle`, `exposureLockCircle`, `steadyToggleCircle`, `liveMomentTrigger`, `rampIntervalCountBadge`, `scannerManualCaptureButton`; `landscapeClusterReadout` hangs under the landscape cluster. Verified 2026-09-04 on the iPhone 16 Pro simulator (portrait, both landscapes) and the Mac.

## Blended clip row — `blended-clip-row.<state>.<width>.svg`

One row of a project's **BLENDED CLIPS** list — `App/ProjectDetailView.swift`'s `versionRow`, repeated once per `AppModel.BlendProject`. Introduced 2026-09-07, migrating markup three iOS `project-detail.*` mirrors had each drawn by hand (identically, in the case of the two interval variants), and reused a third way on the macOS Gallery preview panel, which used to summarise the same data as a single "3 blended clips" text line (see macOS/INDEX.md).

**Coordinate contract.** 1 unit = 1 pt, origin at the row's own top-left. Every row is 62 pt tall regardless of width — 10 pt vertical padding around the 42 pt thumbnail, matching `versionRow`'s `.padding(.vertical, 10)`:

| Width | Total | Thumbnail x | Title/subtitle x | "Open" x (`text-anchor="end"`) |
|---|---|---|---|---|
| `wide` | 361 pt — the iOS project-detail card | 14 | 84 | 347 |
| `narrow` | 272 pt — the macOS Gallery preview-panel column | 14 | 84 | 258 |

(x values are relative to the row's own left edge; `narrow` additionally clips its title/subtitle column — see States)

**Assembly.** A row file draws content only: no divider, no surrounding card — `versionRow` draws the whole tappable row, and a divider is the *container's* line, not the row's. Stack N rows with **no gap** (`y = cardTop + i × 62`); the card behind them is simply `height = N × 62`. Draw one divider `<line>` per internal boundary, from the title column to the row's right inset (`x1 = cardX+84`, `x2 = cardX+width−14`), at `y = cardTop + i × 62` for `i = 1 … N−1`. The section header ("BLENDED CLIPS · N") and the card `<rect>` itself stay with the calling screen, not the component — both are trivial and N-dependent, unlike the row.

**States** — one file per representative row, both widths (six files). Between them every subtitle segment `versionSubtitle` can produce is demonstrated at least once, and the SAME three rows are reused verbatim across every screen that shows them — real content carried over from the pre-component mirrors, not invented per screen:

| File | Shows | Used by |
|---|---|---|
| `default` | "Blended clip 1 · 18 frames · 6.1 s" / "24 fps · yesterday" — the plain case, no codec or true-light segment | `project-detail.interval.portrait`, `.interval.reviewed.portrait` (both drew this exact row before the migration) · macOS Gallery preview (row 1 of 3) |
| `from-codec` | "Blended clip 2 · 100× · 1.2 s" / "30 fps · from ProRes · yesterday" — the `sourceCodecLabel` segment | `project-detail.video.portrait` (row 1) · macOS Gallery preview (row 2 of 3) |
| `true-light` | "Blended clip 1 · 50× · 2.4 s" / "30 fps · true-light · 2 days ago" — the `linearLight` flag | `project-detail.video.portrait` (row 2) · macOS Gallery preview (row 3 of 3) |

`narrow` rows carry the identical title/subtitle strings, clipped to a 160pt-wide column (x 84–244) rather than hand-shortened — the same simplification the searchclip in `macOS/gallery.svg` already makes for its placeholder, and the nearest static equivalent of SwiftUI's own `.lineLimit(1)` truncation on a tighter width.

**Known gap, carried over rather than fixed by this migration:** every row draws a `play.fill` glyph over its thumbnail (`default` also carries an amber backing circle the two video-derived rows don't — a pre-existing inconsistency between them, also carried over unchanged). The current `App/ProjectDetailView.swift` `versionRow` does not actually overlay a play glyph on `ProjectThumbnailView` — this predates the component (all three source mirrors already drew it this way before 2026-09-07), and the three iOS files were already ⚠️ Stale for larger reasons (the `MediaPaneMetrics` rebuild) pending a "mirror after code review" pass. Noted here per the design-sync contract rather than silently fixed or dropped.

**Mirrors.** `App/ProjectDetailView.swift`: `versionRow` (thumbnail → `ProjectThumbnailView`, title → `versionTitle`, subtitle → `versionSubtitle`, trailing `Open` → `model.openBlend`). The macOS Gallery preview panel's list (`App/GalleryPreviewPanel.swift`) is design-first as of 2026-09-07 — not yet wired to a real per-project list; see macOS/INDEX.md. Not yet verified against a running app screenshot on either platform. A **Part 2** (not yet designed) adds filter/sort controls — All · Blends · Time slices, Image/Photo/both — above this list once the list treatment itself is signed off; see LetsLapse/docs/TODO.md.

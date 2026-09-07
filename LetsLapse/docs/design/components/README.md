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
| 3 | bottom-left | AE/AF lock (Interval, Video) · Manual exposure "M" (Photo) | `lock.open` / `lock.fill` · `m.circle` / `.fill` | black padlock on an amber disc · black M on an amber disc |
| 4 | bottom-right | Capture when steady | `hand.raised` / `.fill` | amber glyph; hand badge on the disc |

The padlock is the lock's glyph in every mode **except Photo**. Under Interval's Dynamic and Ladder modes the button locks focus only (the ramp owns exposure) but no longer changes its glyph to say so — decision 2026-09-04; the earlier mirrors drew `camera.metering.center.weighted` there. **Photo mode replaces the padlock with M outright** (2026-09-07, `iOS camera photo mode exploration` handoff): there is no AE/AF lock left to reach in Photo — tapping M seeds both manual-exposure wheels from whatever AE currently reads, which already reproduces the padlock's entire value (freeze the current exposure) before any dial is touched, and tap-to-focus is unaffected. `camera.supportsManualExposure` (`device.isExposureModeSupported(.custom)`, checked live per camera) gates this: on a device/lens without custom exposure — every Mac camera so far, since macOS has no `.custom` exposure mode in this app's model at all — slot 3 falls back to the ordinary padlock even in Photo mode.

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
| `photo-idle` | Photo mode only: slot 3 is M off (graphite), no AE/AF lock drawn | `capture-photo.portrait`, `capture-photo.burst.portrait`, `capture-photo.landscape` |
| `photo-manual` | Photo mode only: slot 3 is M on — black M on an amber disc, same on-treatment as the lock | `capture-photo.manual.portrait`, `capture-photo.manual.landscape` |
| `photo-grid` | Photo mode only, added 2026-09-07: slot 1 is `grid.circle.fill` amber (the grid cycle on Grid or Grid+Level — both read as "on" here, per `GridOverlayState`), slot 3 stays M off — Grid/Level and manual exposure are independent, and this state exists so a grid/level screenshot doesn't also show M engaged | `capture-photo.grid-level.portrait`, `capture-photo.grid-level.landscape` |
| `running` | stop square; slot 1 Dim (engaged), slot 2 Info (off); bottom pair empty | Interval runs, Photo bursts |
| `running.info` | as `running` with Info on | `capture-interval.running.info` |
| `running.mac` | landscape only: stop square, Info in slot 2, no Dim (iOS-only) | the macOS running mirror |
| `running.video` | stop square; slot 1 Dim, slot 2 Info (off); slot 3 the speed-burst / marker trigger, slot 4 the burst count | `capture-video.recording.*` |
| `running.video.info` | as `running.video` with Info on (the marquee shows) | `capture-video.recording.info` |
| `running.scanner` | stop square in a poses-banked ring; slot 4 the manual pose shutter | `capture-interval.scanner*` |

Once a shoot starts the four framing toggles hide in every mode (decision 2026-09-04); the slots stay reserved, so the footprint never changes. Code mirrored the same day: `clusterSlot` in `App/CaptureView.swift` keys on `isCapturing`, not only a movie recording. The run-time Dim / Info toggles (third pass) were mirrored the same day: `dimToggleCircle` / `runInfoToggleCircle`, `seedRunToggles`, the run readout (`runExposureLine`, `runInfoPanel`, `runReadoutCapsule`) in `App/CaptureView.swift`; hooks `LL_RUNINFO=1` and `LL_RUNDIM=off|wake` stage them.

**Mirrors.** `App/CaptureView.swift`: `shutterClusterLayer` (the pin, over both layouts' chrome) → `shutterClusterPin` (94 pt from the home-indicator edge, via the scene's interface orientation) → `shutterCluster` → `clusterSlot` (what each slot holds per state) → `shutterButton`, `shutterBadge`, `gridToggleCircle`, `shutterDelayCircle`, `exposureLockCircle`, `manualExposureCircle` (slot 3, Photo mode only), `steadyToggleCircle`, `liveMomentTrigger`, `rampIntervalCountBadge`, `scannerManualCaptureButton`; `landscapeClusterReadout` hangs under the landscape cluster and, in Photo manual exposure, carries `PhotoExposureWheels` (`App/CaptureDials.swift`) instead of a plain text readout — the one case where that overlay needs real drag room rather than the cluster's own narrow box, so `landscapeClusterReadoutWidth` widens it to 240 pt. Verified 2026-09-04 on the iPhone 16 Pro simulator (portrait, both landscapes) and the Mac; the Photo-only M states verified 2026-09-07 (iOS Simulator build).

**Landscape M states + `photo-grid`, added 2026-09-07 (design-sync pass, Grid+Level).** `shutter-cluster.photo-idle.landscape.svg`, `shutter-cluster.photo-manual.landscape.svg` (both landscape twins of the portrait M states above, same glyphs at the landscape slot offsets) and `shutter-cluster.photo-grid.{portrait,landscape}.svg` (the new state, for the Grid+Level screens). These four are design-only: built by reading `shutterClusterLayer`/`landscapeChromeRail`/`landscapeModeRail`/`photoControlsRow`/`gridToggleCircle` directly and rendered with Quick Look for a static-correctness check, not verified against a running simulator or device build — landscape sign-off is still owed, same as the screens that reference them (see iOS/INDEX.md).

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
| `sliced` | "timeslice-vert-left-segs_24-lag_2 · 2.4 s" / "30 fps · yesterday" — a time-sliced VIDEO export, `blend.timeSlice != nil`; the title is `TimeSliceRecipe.displayName` (`Kit/TimeSlice.swift:164`), not "Blended clip N" | `project-detail.video.filtered.portrait` (Part 2 demo) — added 2026-09-07 for the filter mockup, so filtering to Time slices has something real to show |

`narrow` rows carry the identical title/subtitle strings, clipped to a 135pt-wide column (x 84–219) rather than hand-shortened — the same simplification the searchclip in `macOS/gallery.svg` already makes for its placeholder, and the nearest static equivalent of SwiftUI's own `.lineLimit(1)` truncation on a tighter width. `sliced.wide` needs the same clip (224pt, x 84–308) even at the full 361pt width — it is the one state whose real string is long enough to overflow there too.

**Clip-width trap (found and fixed 2026-09-07):** the clip must end 8pt before "Open"'s own **left edge**, not before its `text-anchor="end"` anchor point. Open's anchor sits at `cardWidth−14`, but the label itself is ~31pt wide and drawn *leftward* from that anchor, so a clip sized off the anchor alone (the first cut of `sliced.wide`/`.narrow` used 255pt/160pt, ending only 8pt before the anchor) still overlaps Open's rendered text once the clipped string is long enough to reach the clip's own edge. Every row's title/subtitle was short enough in Part 1 to never actually reach that far, which is why this went unnoticed until `sliced`'s much longer real string exposed it live in the browser. Fixed by ending each clip 8pt before Open's left edge instead: 224pt (wide) / 135pt (narrow).

**Known gap, carried over rather than fixed by this migration:** every row draws a `play.fill` glyph over its thumbnail (`default` also carries an amber backing circle the two video-derived rows don't — a pre-existing inconsistency between them, also carried over unchanged). The current `App/ProjectDetailView.swift` `versionRow` does not actually overlay a play glyph on `ProjectThumbnailView` — this predates the component (all three source mirrors already drew it this way before 2026-09-07), and the three iOS files were already ⚠️ Stale for larger reasons (the `MediaPaneMetrics` rebuild) pending a "mirror after code review" pass. Noted here per the design-sync contract rather than silently fixed or dropped. Confirmed still real 2026-09-07: verified live on the iPhone 16 Pro Simulator and a fresh macOS Debug build, both showing the same thumbnail with no play glyph.

**Mirrors.** `App/ProjectDetailView.swift`: `versionRow` (thumbnail → `ProjectThumbnailView`, title → `versionTitle`, subtitle → `versionSubtitle`, trailing `Open` → `model.openBlend`). As of 2026-09-07 this is implemented in code too, factored into the shared `App/BlendedClipRow.swift` view that both `ProjectDetailView` and `App/GalleryPreviewPanel.swift`'s new section use. Verified live: iOS Simulator renders `default` and (via the `demo` project) all three video-derived rows exactly per spec; a fresh macOS Debug build renders `default` in the Gallery preview panel. `sliced` is design-only (no code path emits a time-sliced row into either list yet).

## Blend list filter — `blend-list-filter.<state>.<width>.svg`

Part 2 (design-first, 2026-09-07) of the blended-clips-list work: **four independent tick chips** — Blends, Slices, Image, Video — sitting between the "BLENDED CLIPS · N" header and the card. A chip ticked means "include this"; there is no separate "All" control at all, because ticking every chip already IS "All" (Steven's own framing, 2026-09-07, replacing this component's first draft — a pair of All/Blends/Time-slices and All/Image/Video segmented tracks — same day). Semantically the four still pair up into two questions — Blends/Slices ask about `blend.timeSlice == nil` vs `!= nil`, Image/Video ask about `blend.kind` — but nothing in the model enforces that pairing; all four are plain independent booleans, and a project's results are shown when they match ANY ticked value in each pair (i.e. unticking both Blends and Slices, or both Image and Video, shows nothing — a real, allowed empty state, not a bug to guard against). The header's own count reflects the *filtered* result count, not the project's total — see `project-detail.video.filtered.portrait.svg`, where a project with 3 results reads "BLENDED CLIPS · 1" once Blends is unticked.

**Why individual chips, not a segmented control.** The first draft of this component borrowed `App/CaptureFilterBar.swift`'s exact segmented-track rendering (gray track, sliding white pill, one selection per facet) — the natural reach for "pick one of a few options" in this app. But that control is built for MUTUALLY EXCLUSIVE choices, and a facet with an explicit "All" segment alongside "Blends"/"Time slices" is really doing double duty as a boolean pair wearing a 3-way exclusive-picker costume. Once every chip is independently tickable, the app's OWN closer precedent is the preset strip immediately above this section on every one of these same screens (`project-detail.*.portrait.svg`'s `preset-strip`): individual floating capsule pills, accent-filled when active, white-with-shadow when not, no surrounding track. This filter reuses that exact visual spec — height, corner radius, font, fill colors — and adds only a small checkmark glyph on ticked chips, since unlike the preset strip (single-select) this control needs to say "more than one of these can be true at once." The segmented style is still right for genuinely exclusive choices (`CaptureFilterBar` itself, unchanged); it was simply the wrong shape for this control once the interaction became "tick any subset."

**Coordinate contract.** 1 unit = 1 pt, origin at the block's own top-left; width matches whatever card the block sits above. Chip height is always 33 pt (`preset-strip`'s own height), `rx=16.5`; a normal gap between adjacent chips is 8 pt (`preset-strip`'s own gap). The two semantic pairs are marked without a divider or track:

- `wide` (361 pt, the iOS project-detail card): all four chips fit one row; the pair boundary is a **16 pt gap** between Slices and Image instead of the usual 8.
- `narrow` (272 pt, the macOS Gallery preview-panel column): four chips don't fit one row at this width, so they **wrap to two 33 pt rows**, 8 pt apart (row 2 at y=41) — Blends/Slices on top, Image/Video below. The row break marks the pair boundary here instead of an extra gap, for free.

A ticked chip is `fill=#C36A00` (accent) with white `font-size=13.5` class `sb` (semibold) text and a small white checkmark (`M{x} {y} l2.5 2.8 l5 -5.5`, `stroke-width=1.8`, round cap/join) 14pt in from the chip's left edge, text starting 27pt in (14 + 9pt checkmark + 4pt gap). An unticked chip is `fill=#FFF` with the file's `#soft` drop-shadow (matching `preset-strip`'s own unselected chips exactly) and **black** text with **no checkmark**, text starting 12pt in — so an unticked chip is narrower than its ticked self, the same way a SwiftUI HStack chip would naturally shrink without the checkmark's reserved space; toggling a chip is expected to visibly resize it, not just recolor it.

| Chip | Ticked width | Unticked width | Facet |
|---|---|---|---|
| Blends | 84 | 64 | Type (`timeSlice == nil`) |
| Slices | 78 | 58 | Type (`timeSlice != nil`) |
| Image | 76 | 56 | Kind (`.image`) |
| Video | 76 | 56 | Kind (`.video`) |

**States** — one file per representative selection, both widths (four files):

| File | Blends | Slices | Image | Video | Used by |
|---|---|---|---|---|---|
| `all` | ✓ | ✓ | ✓ | ✓ | Every "at rest" screen — `project-detail.interval[.reviewed].portrait`, `.video.portrait`, macOS Gallery preview |
| `slices` | — | ✓ | ✓ | ✓ | `project-detail.video.filtered.portrait` — the one state that actually narrows a real list (3 results → 1) |

More combinations (single chips off, several off at once, the real all-off empty case) follow the exact same per-chip rule above rather than needing their own file — the same way `blended-clip-row`'s three states don't enumerate every real subtitle combination either.

**Empty state — shipped as `BlendListEmptyState` (`App/BlendListFilter.swift`), simpler than first specified.** A combination with zero matches — e.g. Image unticked on an all-video project, or Blends AND Slices both unticked — replaces the card with a message in the same visual language as Gallery's own empty grid (`macOS/gallery.svg`'s "No projects" state): a secondary-color SF Symbol (`line.3.horizontal.decrease.circle` — a filter glyph, not `photo.on.rectangle`; this is "your filter has nothing to show," not "you have nothing"), 16pt semibold "No results" under it, and a 13pt secondary "Try ticking another chip back on." The first draft of this note proposed naming the specific excluded facet ("No results are Video — try ticking it back on"); shipped code uses the generic line instead, because with four independent chips there is often no single chip to name — two or three could be off at once — and a precise sentence describing every excluded combination reads worse than a generic one. The header count still reads the filtered "· 0".

**Mirrors.** `App/ProjectDetailView.swift`'s `blendedClipsSection` and `App/GalleryPreviewPanel.swift`'s `blendedClipsSection` both filter through the shared `BlendListFilter.matches` and show `BlendListFilterBar` / `BlendListEmptyState` from `App/BlendListFilter.swift` — wired and verified live 2026-09-07 on both platforms, including against a real project with a mixed blend + time-slice list (unticking Blends correctly dropped the regular blend and kept the time-sliced result, header count 2 → 1). See `docs/TODO.md` for status.

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

## Tag editor — `tag-field.<state>.<width>.svg` + `tag-suggestions.<state>.svg`

A project's subject tags, wherever they can be read or changed. Introduced 2026-09-08 to answer a
plain gap: tags could only ever be *removed*, and only during the one run of Auto rename & tag that
proposed them. There was no way to add a tag the model never thought of, no way to type one of your
own, and — because `AutoNameSheet`'s section is wrapped in `if !proposal.tags.isEmpty` and
`managementCard`'s row in `if let tags, !tags.isEmpty` — no tag UI *at all* on a project the
analysis returned nothing for. One component now serves every door, on both platforms, for Photo,
Interval and Video alike (all three are one `CaptureProject` with one `sceneTags` field; nothing
here reads the shoot type).

**Two flat files, never nested.** A screen stacks them; neither references the other, because an
`<image>` inside an `<image>` is not reliably followed by every viewer this repo has to render in.

| Piece | What it is | Where it goes |
|---|---|---|
| `tag-field` | the applied tags, one accent capsule each with an xmark that drops it, then a dashed **+ Add tag** chip | anywhere tags are *shown* — the Auto rename & tag sheet's SUBJECT TAGS, the macOS Gallery preview panel's TAGS block, the top of the picker itself |
| `tag-suggestions` | a field that both filters and creates, then **SUGGESTED** (the closed taxonomy) and **YOUR TAGS** (custom tags already in this library) | the picker — an iOS sheet, a macOS popover |

**Nothing is ever drawn twice.** A tag is either applied (in the field) or offered (in the
suggestions), never both, so there is no tick state to reconcile and no way to see the same word in
two places. Tap a suggestion and it moves up; tap an xmark and it moves back down. That is also why
`tag-field` has a `plain` state: inside the picker the search field is already the add affordance,
so the **+ Add tag** chip would be a second one.

**Coordinate contract.** 1 unit = 1 pt, origin at the block's own top-left. Chips are 33 pt tall at
`rx=16.5` in a wrapping flow, 8 pt between chips and 8 pt between rows — `blend-list-filter`'s own
metrics, which are `preset-strip`'s before that. Widths are the *content box* of whatever the block
sits in, so a file is placed at its natural size and never scaled:

| Width | Total | Container |
|---|---|---|
| `wide` | 329 pt | an iOS card's content box — the 361 pt column less 16 pt padding each side. Also the macOS sheet's, which is why that sheet is specified at 393 pt (see `macOS/auto-name.svg`): at AppKit's own ~470 pt the box is 406 and the chips wrap differently for no reason a reader could name |
| `narrow` | 272 pt | the macOS Gallery preview panel's column. The tag block is promoted OUT of the 72 pt-label metaRow grid to full width — at 190 pt a single "Sky & weather" chip is nearly the whole row |

`tag-suggestions` is `wide` only. A Mac popover is free to be 361 pt whatever panel raised it, so
one file serves both platforms.

**Chip treatments.** An applied chip is `fill=#C36A00` with a 14 pt semibold white label 12 pt in,
an xmark (`stroke #FFF` at 80%, 1.7 pt, round caps) 8 pt after it and 12 pt right pad — **width =
text + 41**, the same arithmetic a ticked `blend-list-filter` chip uses. An offered chip is the
app's own unselected treatment, black at 7% with a 14 pt regular label at 75%, 12 pt each side —
**width = text + 24**. The **+ Add tag** chip is white with a 1.2 pt dashed `#C36A00` border
(`stroke-dasharray="4 3"`), a `plus` glyph and a 14 pt medium accent label: 92 pt, and it always
sits **last** in the flow.

**Why an xmark and not the tick this sheet used to draw.** A tick answers "is this one of the
options?", which is the right question in a filter (`blend-list-filter` keeps it) and was a
defensible one while these chips only ever existed inside a proposal you were paring back. It is
the wrong question on a settled project, where everything drawn IS applied and the only thing you
can do to a chip is remove it. One idiom now covers the proposal and the project, which is what
lets `AutoNameSheet` and the Gallery panel show literally the same file.

**States** — five field files, two suggestion files:

| File | Shows | Used by |
|---|---|---|
| `tag-field.applied.wide` | the canonical five tags plus **+ Add tag**, two rows | `iOS/auto-name.portrait`, `macOS/auto-name` |
| `tag-field.applied.narrow` | the same five, three rows at 272 pt | `macOS/gallery`, `macOS/gallery.tags` |
| `tag-field.plain.wide` | the same five, no **+ Add tag** — the picker's own applied row | `iOS/project-tags.portrait`, `iOS/project-tags.adding.portrait` |
| `tag-field.empty.wide` / `.narrow` | nothing applied: the **+ Add tag** chip alone | `iOS/auto-name.no-tags.portrait`; `.narrow` is drawn for the Gallery panel's own empty project, which no screen file exercises yet |
| `tag-suggestions.default` | the field at rest, SUGGESTED + YOUR TAGS | `iOS/project-tags.portrait`, `macOS/gallery.tags` |
| `tag-suggestions.filtered` | "Harbour" typed, nothing matching, the Create row | `iOS/project-tags.adding.portrait` |

The canonical demo content is one set everywhere: **Water · Sky & weather · Urban · Nature** from
the taxonomy, plus **Rooftops**, typed by the user. A custom tag is drawn identically to a taxonomy
one on purpose — once applied there is no difference worth showing, and the whole point of the pass
is that the model's guesses and your own words end up in the same field. The set is chosen to make
the two widths genuinely different rather than coincidentally equal: "Sky & weather" is long enough
that 272 pt takes three rows where 329 pt takes two. `YOUR TAGS` carries **Prague** and **Client
work**, custom tags this library holds but this project does not.

A partial match — text typed that some tag does contain — needs no file of its own: the Create row
sits above whatever survives the filter, in `default`'s own layout. Same rule as
`blend-list-filter`, which does not enumerate every tick combination either.

**What this asks of the code, beyond the views.** `sceneTags` is a closed taxonomy today:
`SceneAnalyser`'s parser drops anything outside `SceneMetadata.orderedTaxonomy`, and
`App/SceneSearch.swift`'s `availableTags` filters the library's tags back through it before the
Gallery sidebar draws its chip rows. A tag the user typed passes neither. Both have to widen, or a
created tag is findable by search (which matches raw strings) and invisible as a sidebar chip —
which is why `macOS/gallery.svg`'s sidebar grows a "Rooftops" row in this pass. The parser's filter
should stay exactly as it is: it exists to stop a 4-bit model inventing labels, not to stop a
person naming their own work.

**Mirrors.** Implemented 2026-09-08, the same day these were drawn, in `App/TagEditor.swift`:
`TagField`, `TagSuggestions`, `TagPickerSheet` and the `.tagPicker` modifier that presents a sheet
on iOS and a popover on the Mac. `ChipFlowLayout` moved there from `AutoNameSheet`. The three call
sites are `App/AI/AutoNameSheet.swift` (SUBJECT TAGS — its `if !proposal.tags.isEmpty` guard gone,
its `Proposal.Tag` tick model replaced by a plain `[String]`), `App/ProjectDetailView.swift`
(`managementCard`'s Tags row — unconditional, a `Button` with a chevron, "Add" when empty) and
`App/GalleryPreviewPanel.swift` (`tagsSection`, out of the metaRow grid). Writes go through
`AppModel.setSceneTags`, which trims, canonicalises against the taxonomy and de-duplicates
case-insensitively, so "water", "Water" and "Sky & weather" all join the existing tag rather than
sitting beside it as a near-duplicate.

Verified live on the iPhone 16 Pro Simulator; the macOS Gallery panel and `AutoNameSheet` were signed off by Steven on
his own Mac, 2026-09-08.

`SceneTagLine` itself stays exactly as it is: it is a *summary* for a list row (`ProjectsView`, and
the Gallery tiles), not an editor, and it is correct there.

## Metadata record — `metadata-scope.<state>.narrow.svg` · `metadata-info.<state>.<width>.svg` · `metadata-fields.<state>.<width>.svg` · `tag-field.imported.<width>.svg`

The Gallery preview panel's INFO and METADATA groups — what a project's files said and the
IPTC Core record a person edits — on every platform. Introduced 2026-09-13 with data model
Milestone 1 (`docs/data-model-scale-and-metadata-2026-09-12.md` §4 and §7), code first,
mirrored the same day after Steven's sign-off: `App/MetadataPanelSections.swift`
(`MetadataScopeControl`, `MetadataInfoSection`, `MetadataEditSection`) inside
`App/GalleryPreviewPanel.swift`'s `recordSections`. The same three views draw the Mac's 300 pt
panel, the iPad's 300 pt panel and the iPhone's preview sheet, so one set of files serves all
three — Steven's instruction for this pass: document it once.

**Three flat files, stacked by the screen 14 pt apart, never nested.** Like the tag editor, an
`<image>` inside an `<image>` is not reliably followed, so the Keywords row — the METADATA
group's last row — is *not* inside `metadata-fields`: the screen draws its two-word label line
("Keywords" 12 pt semibold secondary, the origin marker trailing) and places the existing
`tag-field.<state>.<width>` 4 pt under it. That is also what keeps the tag editor one component:
the panel's Keywords row IS the tag editor, since tags became keywords in this pass.

**2026-09-13, later the same day (design-first, implemented the same day):** the Keywords row is gone again. Tags are the
highest-priority metadata a person manages (Steven), so the tag editor is its own TAGS block directly under the
action grid, ABOVE INFO — the origin marker and revert on its header line — and METADATA ends at Country code in
both scopes. Still one component, still one list (tags ARE keywords; the block is always the whole project's —
per-frame keywords a file carried stay stored and exported, not edited here). A collapsible PRESETS row follows
TAGS, then the scope switch, INFO and METADATA — `macOS/gallery.svg`, `gallery.metadata.svg`, `gallery.tags.svg`,
`gallery.presets.svg` and `iOS/gallery.preview*.portrait.svg` draw the order; `metadata-fields.*` is unchanged.

| Piece | What it is | Where it goes |
|---|---|---|
| `metadata-scope` | Whole project / This frame, a 22 pt segmented picker on `LL.controlFill`; the `frame` state adds the stepper (‹ · file name over "n of N" · ›, 28 pt square buttons, the back chevron dimmed on the first frame) | first, and only for an interval project — a Photo or video project is one asset and shows nothing here |
| `metadata-info` | the read-only group: `LLSectionHeader` INFO, then a 72 pt label column and the value, 25 pt per single-line row, 14.5 pt per extra line. Rows exist only when the resolved record has them; GPS carries the Open in Maps link | under the scope switch (or the divider) |
| `metadata-fields` | the editable group: `LLSectionHeader` METADATA, then Title, Caption, Creator, Copyright, Rating, Copyright status, Copyright URL, Usage terms, the Creator contact block (Address … Website) and the Location block (Sublocation … Country code), rows 10 pt apart | under INFO; nothing after it since 2026-09-13's later pass (the Keywords row moved up to the TAGS block) |
| `tag-field.imported` | the tag editor with the seven keywords a file carried | the TAGS block of a project whose keywords came from its files (until 2026-09-13's later pass, METADATA's Keywords row) |

**Origins, per row.** Every METADATA row says where its value came from, 10 pt medium at the
trailing edge of the label line: **from file** (black at 30%) when the value is the file's own —
the record's `imported` layer, read from XMP, IPTC-IIM or Exif at import, the `.xmp` sidecar
winning over the raw; **edited here** (`LL.accent`) with a 10 pt `arrow.uturn.backward` revert
6 pt after it when a person changed it in this app — the `edited` layer, one line appended to
`assets.ndjson` (or `metadata.json` for the whole project) with `editedAt`/`editedBy`; nothing
when the record has no value. Revert drops the edited value and the file's returns. Edits never
touch the original file. A project tagged before the records existed shows its manifest tags
as edited here; the first edit writes them into the record for good.

**Coordinate contract.** 1 unit = 1 pt, origin at each block's own top-left. Two widths, chosen
by the container, and — because the same SwiftUI draws AppKit controls on one and UIKit on the
other — the width also chooses the control metrics:

| Width | Total | Container | Controls |
|---|---|---|---|
| `narrow` | 272 pt | the macOS Gallery preview panel's column (the 300 pt panel less 14 pt each side); also the iPad's identical panel | AppKit: `.roundedBorder` fields 22 pt, rx 4; Copyright status a full-width `NSPopUpButton` with the accent up/down control trailing; the segmented picker 22 pt |
| `phone` | 365 pt | the iPhone preview sheet's column (393 pt less 14 pt each side) | UIKit: fields 33 pt, rx 5, `#C6C6CB` border; Copyright status an `LL.accent` `.menu` label with `chevron.up.chevron.down`; Caption wraps (1–4 lines) where the Mac's clips at one |

The iPad panel is the narrow width drawn with the phone file's control heights; no third file
— its INDEX row leans on the Mac's, as it did before this pass. A `metadata-fields` row is
2 pt padding + the label line (14.5) + 4 pt + the control + 2 pt; a single-line INFO row is 25 pt.
Widths are the content box, so a file is placed at its natural size and never scaled; INFO's
narrow values wrap at 176 pt (measured against the running panel), phone's at the full column.

**States:**

| File | Shows | Used by |
|---|---|---|
| `metadata-scope.project.narrow` | Whole project selected | `macOS/gallery.svg`, `macOS/gallery.tags.svg` |
| `metadata-scope.frame.narrow` | This frame, with the stepper on frame-00001.jpg · 1 of 12 | no screen file yet — the state the Mac panel showed live 2026-09-13 |
| `metadata-info.photo.narrow` / `.phone` | everything the `_WEX3518` ARW + sidecar said: camera, lens, exposure, captured in the file's zone, GPS + map, size + format, software | `macOS/gallery.metadata.svg`, `iOS/gallery.preview.portrait.svg` |
| `metadata-info.interval.narrow` | an iPhone JPEG shoot's whole project — only Size is true of every frame | `macOS/gallery.svg`, `macOS/gallery.tags.svg` |
| `metadata-fields.file.narrow` / `.phone` | the ARW's record with all three treatments: from file (Caption, Creator, Copyright, Rating 5 — the sidecar wins over the ARW's own 0 — Sublocation, State, Country, Country code), edited here + revert on Title, nothing on the empty rows | `macOS/gallery.metadata.svg`, `iOS/gallery.preview.portrait.svg` |
| `metadata-fields.empty.narrow` | nothing from the files: no markers, the placeholders showing (Name, name · © year name · https://) | `macOS/gallery.svg`, `macOS/gallery.tags.svg` |
| `tag-field.imported.narrow` / `.phone` | Bridge · Czech Republic · Dusk · Historic · Prague · River · Vltava, then **+ Add tag** | the Keywords row of the two photo screens above |

Copy-only variants need no file: INFO's "Reading the files…" (before the reader lands),
"Varies by frame — choose This frame." (an interval project whose frames disagree) and
"Nothing in the file." are one 12 pt secondary line in the group's own layout; a Photo project
tagged by the app shows `tag-field.applied.*` under a "Keywords · edited here ↩" label, which
is what `macOS/gallery.svg` draws.

The demo content is the Milestone 1 test set (`/Users/stevenwright/Desktop/Lightroom Exports`,
imported by copy): `_WEX3518.ARW` with its Lightroom `.xmp` sidecar, whose values the panel was
verified against on the Mac, the iPhone 16 Pro and the iPad Pro simulators, 2026-09-13. Title
is drawn edited ("Charles Bridge, blue hour" over the sidecar's "Charles Bridge at night") only
to show the third treatment; the empty state is an untouched iPhone shoot.

**Mirrors.** `App/MetadataPanelSections.swift` (the three views, the row frame with its marker
and revert, the commit-on-Return text row), `App/AppModel+Metadata.swift` (the resolution
chain asset edited → project edited → asset imported → project imported, the manifest-tags
fallback for keywords, the writes), the records in `Kit/Sources/LetsLapseKit/Library/AssetRecords.swift`,
the reader in `Kit/…/Metadata/`. Screens: `macOS/gallery.svg` (interval, at rest),
`macOS/gallery.metadata.svg` (the imported photo), `macOS/gallery.tags.svg` (the panel scrolled
to Keywords, picker open), `iOS/gallery.preview.portrait.svg` (the iPhone sheet on the photo).

## Library banner — `library-banner.unreadable.<width>.svg`

`LibraryUnreadableBanner` in `App/LetsLapseApp.swift`: the card over every tab, on every
platform, while `Projects/library.json` could not be decoded at launch (data model Phase 1
W7, code first 2026-09-13, mirrored after sign-off). The manifest is moved aside as
`library.json.unreadable-<stamp>` — never overwritten, since it is the only copy of every
grade, tag and blend record — the library loads empty and every write is refused until the
app is relaunched against a repaired or restored file. The card says so: a 13 pt semibold
title, then the decoder's own reason, the set-aside name and what to do, 12 pt secondary;
`exclamationmark.triangle.fill` in `LL.amber` leading; 12 pt padding, rx 12, a 1 pt `LL.amber`
border at 60% on `LL.cardBackground`. It overlays the tab (a `VStack { banner; Spacer() }` at
zIndex 50), 14 pt in from the edges and 8 pt under the top safe area, and pushes nothing.

| Width | Total | Container |
|---|---|---|
| `phone` | 365 pt | a 393 pt iPhone screen less 14 pt each side — `iOS/create-home.library-unreadable.portrait.svg` |
| `window` | 732 pt | the macOS default 760 pt window less the same; no Mac screen file — placement is the same, so the INDEX row points here |

Height follows the wrapped detail (115.5 pt at `phone`, 86.5 at `window`). One state: there is
no in-app repair before Phase 4's reconciliation, so the banner has nothing to offer but the
facts. Verified on the running Mac Debug build against a scratch library whose manifest was
corrupted by one byte, 2026-09-13.

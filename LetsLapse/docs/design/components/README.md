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
- macOS capture sheet (960×720 at 20,20): no device edge to pin to. The ring keeps its rail height and the landscape cluster is fitted 8 pt inside the sheet's right edge: ring (894, 314) → image x 814, y 254. It overhangs the viewfinder column by 46 pt.

**Rotation.** The ring never moves: the interface reflows but the cluster's centre stays on the same physical spot. The four circles do **not** keep their physical spots across a turn — the wide portrait 2×2 becomes the narrower, taller landscape 2×2 around the same ring. Steven chose this on 2026-09-04 over a diamond that would have kept them fixed, because the diamond wasted the rail's height in landscape and needed the portrait mode row moved up. Glyphs stay upright in the viewer's frame; slot numbering (1/2 top, 3/4 bottom) is the viewer's frame in both orientations.

**States** — one file each, per orientation (twelve files):

| File | Shows | Used by |
|---|---|---|
| `idle` | red disc, four toggles off | every idle capture mirror |
| `armed` | every toggle on plus both badges — the ON reference | no screen directly |
| `locked` | AE/AF held, the others off | `capture-exposure-locked` |
| `running` | stop square, **all four slots empty** | Interval runs, Photo bursts |
| `running.video` | stop square; slot 3 the speed-burst / marker trigger, slot 4 the burst count | `capture-video.recording.*` |
| `running.scanner` | stop square in a poses-banked ring; slot 4 the manual pose shutter | `capture-interval.scanner*` |

Once a shoot starts the four framing toggles hide in every mode (decision 2026-09-04); the slots stay reserved, so the footprint never changes. The code today hides them only for Video (`camera.isRecording`) — Interval runs and Photo bursts still show them live. Code mirror owed: `docs/TODO.md`.

**Mirrors.** `App/CaptureView.swift`: `shutterButton`, `shutterBadge`, `gridToggleCircle`, `shutterDelayCircle`, `exposureLockCircle`, `steadyToggleCircle`, `leadingControl` / `trailingControl` (portrait row), `landscapeExposureControl` (landscape rail), `scannerManualCaptureButton`.

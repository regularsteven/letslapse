# Text, Masking & Intelligent Placement — spike report

2026-08-31 · macOS Edit window · test subject: *River Sunset to Dusk*
(`E39131D4-6C53-4601-A0E4-27C5B5AD1F37`, 602 DNG interval, 4032×3024,
sunset→dusk over 55 min). Spike brief: manually-placed text overlays,
semantic sky/land masking that lets the scene occlude them, mask debugging,
temporal stability, and per-character reveal animation on the existing
timeline. This report answers the brief's discovery questions and records
what shipped, what's owed, and what was learned.

## What shipped (all verified live on the Mac against the test project)

- **Three-tab rail** `[Editor | Text | Frames]` in both editors
  (`RailTabBar`; `PhotoViewerView.controlStack` switched, `VideoEditorView`
  twin split with an honest placeholder Text page). Frames only exists where
  frames do (interval); a single still gets `[Editor | Text]`.
- **Overlay model** — `SceneOverlay { content, centerX/Y (unit, top-left),
  size (fraction of long edge), placement, animation }` with tag-based
  `OverlayContent` (text today, `.svg`/`.image` decode-safe later). Persisted
  per project as `overlays.json` (FieldNoteStore pattern) — survives
  relaunch; deliberately not in `library.json` while the schema is
  experimental.
- **Preview drag** — SwiftUI proxy over `picture(in:)`, active on the Text
  tab: baked at rest, proxy-during-drag (bake suppressed for that overlay),
  kenBurns drag idiom (frozen base + translation ÷ drawnSize, unit-clamped),
  commit + persist on release, `@GestureState` cancel-healer.
- **Text raster** — `TextOverlayRasterizer`: CoreText per-glyph draw into a
  frame-sized context, grapheme-cluster animation units, size resolved
  against the actual render long edge (2000 settled / 1100 scrub), one
  shadow for contrast, NSCache'd, and **byte-identical settled vs
  no-animation rasters** (the "final layout is always the end state"
  guarantee is structural).
- **Segmentation** — Apple's `coreml-detr-semantic-segmentation` (FP16,
  85 MB, 448×448 argmax, COCO-panoptic; sky = label 187 "sky (other)"),
  wired into **Settings ▸ AI Models** as a real catalog entry
  (`engine: "coreml"`, downloads via the existing SnapshotDownloader). The
  Text tab works fully without it and says exactly where to get it.
- **Scene-aware compositing** — `SceneAwareCompositor` (Core Image):
  threshold → open/close → conservative-edge erosion → clamped feather →
  `CIBlendWithMask` with the pristine graded frame as the restored input.
  Sky/Land are one analysis read two ways (`SceneMask.inverted()`).
- **Mask caching** — `SceneMaskStore` (raw grids as lossless gray PNG under
  `StorageRoot/SceneMasks`, added to `libraryItemNames`), NSCache in front,
  in-flight coalescing in `actor SceneMaskService`. Post-processing dials
  live OUTSIDE cache keys, so threshold/feather/bias iterate with zero
  re-inference. **The composite path is cache-only by API shape — a drag can
  never trigger inference.**
- **Mask debug** — "Show semantic mask" tints the post-processed sky region
  magenta over the live composite; a provenance line shows model id,
  revision, inference ms / cache state / "sequence vote · N frames".
- **Temporal stability** — default sequence mask: 9 frames sampled evenly
  (bad frames excluded), per-frame grids averaged into a vote-confidence
  grid, thresholded live. "This frame" mode for drift inspection.
- **Animation** — character fade + directional slide (top/bottom/left/
  right), stagger with overlap 0.6, `ReframeTrack.ease`, authored as
  **source-position 0…1** via Set Start / Set End at the playhead, passive
  range band under the strip (drawn with the newly extracted
  `GradeTimelineView.leadInset` — the hand-copied lead constant trap is
  dead). Reveal renders live during scrub AND playback.
- `LL_EDITOR=<capture-uuid>` now stages the editor on a specific project
  (`latest` unchanged). `LL_SEG_MODEL=<path>` loads a segmentation model
  from disk for bench runs.
- Standalone harness `tools/seg_harness.swift` (`describe` / `run`) — mask +
  tint-composite PNGs, per-frame class histograms, timings. The regression
  check for any post-processing change.

## The brief's §30 walkthrough — performed

Add text → drag across the skyline → Show Mask (boundary hugs hills,
rooflines, the bridge, even lamp posts) → Placement Sky (buildings and the
hillside clip the descenders of "PRAGUE"; word stays readable) → Land (exact
inverse: only rooftop-crossing fragments survive) → Fade with Set Start
0:00 / Set End 5:08 → scrub: absent before the band, "PR" + fading "A" at
2:13, byte-exact final layout past 5:08 → play: frames and reveal advance
together. Position never moved except by hand.

## Answers to the discovery questions

1. **Sky accuracy.** Very high on this footage across the entire
   sunset→dusk ramp — including full night (frame 602: streetlights,
   near-black hill; the boundary still follows the ridge). Sky fraction
   drifts only 48.0% → 46.8% over 55 min. The known caveat is grid
   coarseness, not classification: 448×448 stretched over 4032×3024 means
   ~9 source px per grid cell, so fine structures (thin poles, wires) are
   quantized — feather hides most of it at preview size.
2. **Land as inverse of sky.** Yes, and cheaply — `1 − sky` is exactly the
   right first "land". The model also emits river/water/building/tree/fence
   separately (measured: river 16–26%, fence up to 21%, building ~5%), so
   the future `SceneRegion.person/.water/.building` cases have data waiting
   in the same argmax map.
3. **Horizon quality.** Ridges, rooflines and the bridge deck read
   convincingly; lamp posts are correctly excluded from sky (visible in the
   debug tint). Trees and filigree (the embankment railing) are where the
   448 grid rounds — the conservative edge-bias erosion is the right
   default because under-occlusion reads fine and over-occlusion reads
   broken.
4. **Post-processing recipe.** Threshold 0.5 → morphological open+close
   (r=2 grid px) → erode the restoring region by `edgeBias` (default 1.5) →
   `clampedToExtent` + Gaussian feather (default 2.5 grid px ≈ 22 px at
   4032) → clamp. All live dials; total <1 ms at grid res. The
   `clampedToExtent` before the blur is load-bearing (without it the mask
   fades at frame borders and edge sky leaks over edge text).
5. **Speed.** Warm inference 42–95 ms/frame on the M4 Max (first in-process
   pass ~110 ms incl. model load from the compiled cache; very first launch
   pays a one-time ~2 s Neural Engine compile). 512-px graded input render
   ~150–500 ms (CIRAWFilter decode dominates). Interactive per-frame
   analysis is fine as a debounced settle; a 9-frame sequence pass lands in
   a few seconds.
6. **Reduced resolution.** 448 stretched (not letterboxed — the
   `MaskGeometry.stretch` contract kills the whole un-padding bug family)
   is enough for convincing typography occlusion at preview size after
   feathering. Full-res export will want either SegFormer@512+ or simply
   more feather; revisit when export lands.
7. **Temporal stability (measured, 12 frames across the ramp).**
   Consecutive-mask disagreement 0.13–0.40% of pixels through daylight,
   0.87% worst at deep dusk; **98.31% of pixels are unanimous across all 12
   samples** — the contested 1.69% is the boundary band. Per-frame masks
   would micro-flicker letter edges at dusk; they never lose the skyline.
8. **Is the vote mask enough?** Yes, for a locked-off interval shoot — the
   9-frame mean-vote grid thresholded at 0.5 produced a single stable matte
   that looked identical to the good per-frame masks and cannot flicker by
   construction. Anything fancier (EMA, per-frame with hysteresis) is not
   needed for this footage class; revisit only for moving cameras.
9. **Renderer fit.** Clean. The composite slots AFTER `PhotoGrader.render`
   returns its (cached) CGImage in `PhotoViewerView.render()` — the grade
   cache key is untouched, animation phases never thrash it, and a text
   drag costs one CI composite of a cached base. Export parity is the
   documented follow-up: the same compositor call belongs at
   `PhotoPreset.engineRender` (:298/:305, via `LinearFrameDecoder
   .image(from:)`) for stills/JPEG, `ImageStacker.stackSequenceLinear`
   (:523, between `outputGrade` and `encodeGamma`) for blended clips, and
   the `VideoGrader`-family composition handlers for movies — **each export
   gate (`willBakeGrade`, `hasTailPass`, the `grade.isKeyframed` map gate)
   currently assumes "grade is the only reason to run a pass" and must
   learn "or overlays exist" or overlays will silently vanish from
   exports.** Known preview gaps, accepted for the spike: the pixel-peep
   detail patch and loupe render without overlays, and `PhotoDetailFocus`
   now scans the composited preview (the loupe can point at text).
10. **SVG-overlay generality.** Held. Nothing in segmentation, caching, or
    compositing knows about text: the compositor takes premultiplied pixels
    with alpha; `OverlayContent` is a tagged enum; a `.svg` case needs a
    rasterizer and a panel section, nothing else.
11. **Timeline/keyframe fit.** Reveal ranges are source-position 0…1 — the
    grade strip's own axis, inheriting `GradeKeyframe.position`'s
    speed-layer immunity, and export passes would resolve them through
    `GradeSourceMap` exactly like keyframed grades. `GradeTimeline` itself
    was NOT generalized (it is concretely typed to `PhotoAdjustments`);
    that stays the right call until a second animated property family
    exists. Set-Start/Set-End-at-playhead beat draggable band handles: zero
    new gesture arbitration on a strip that already juggles scrub +
    keyframe-press + long-press-delete.
12. **Photo output-timeline assumptions.** None introduced. Every time
    value in the overlay system is an abstract 0…1 `position` (or the
    strip's existing conventions); frame indices appear only where they
    always did (`FrameAxis` resolving which still to decode). A future
    still-photo output duration drives identical overlays by feeding output
    progress as `position`. The Photo editor already shows the Text tab
    (placement, no animation section) untouched by any of this.

## Export baking (shipped same day, commit 864c5f5)

Blended clips, timelapses and long exposures from stills projects now BAKE
the project's text overlays — verified end-to-end by seeding a cold project
(no cached mask, editor never opened), rendering a 107-frame 4K blend
through the app's own New-blended-clip flow (~20 s including the mask
generation), and inspecting the output MP4: no text before the reveal
band, staggered fade mid-band, and the settled word occluded by the night
skyline exactly as the editor previews it. The blend summary records
"text baked in (scene-placed)".

Design:
- `ImageStacker` (both the linear and legacy gamma paths) gained an
  `overlayComposite` hook at the one honest seam: AFTER `encodeGamma` and
  color tagging, BEFORE the writer append — the frame is display-referred
  there, so the bake composites exactly what the preview composites. The
  hook returns a replacement buffer allocated from the writer's own pool
  (never in-place — Core Image on shared memory is undefined) and receives
  the same source-position value `outputGrade` gets, which is what makes
  overlay animation follow warps and exclusions precisely like keyframed
  grades.
- `OverlayExportBake` resolves everything BEFORE the render loop starts:
  overlays, the mask dials, and the sequence mask itself — fetched
  cache-first and GENERATED on a cold cache (a few seconds, up front), so
  the blend loop composites from values and never waits on inference. The
  editor and the export build identical mask cache keys: a mask either one
  computes is a hit for the other.
- Degradation mirrors the preview rule: no model installed (or
  segmentation fails) → the text bakes as a plain overlay, which is
  exactly what the preview shows in that state.
- Mask settings moved into the sidecar (`OverlayDocument` — overlays +
  dials; the spike's bare-array files still decode), because the export
  needs the threshold/feather/bias the preview was tuned with. Export
  always uses the SEQUENCE mask — "This frame" is a drift-inspection mode,
  not an output mode.
- Long exposures (`stackPhotos`) bake at position 1: the whole shoot folds
  into one moment, so every reveal is complete. Photo-mode stacks are
  untouched — that stack is the project's non-destructive ASSET, and
  nothing bakes into it.

Still out (unchanged non-goals): video-source blends and their tail-pass
gates (no overlays can be authored on movies yet), and the Ken Burns
collection export.

**The iOS trap (2026-08-31, found on Steven's iPhone 16 Pro):** the first
device render of a 1250-frame 4032×3024 shoot failed while the same code
passed on the Mac. Cause: `ImageStacker`'s output-frame section had no
`autoreleasepool` — the accumulate loop above it does — so the Core Image
temporaries the bake introduced lived until the whole render returned.
Measured with a standalone writer harness: **~55 MB per frame, 351 MB →
4.5 GB over 80 frames**, unbounded. macOS absorbs that on swap (which is
exactly why the Mac verification passed and hid it); iOS answers with a
jetsam kill. Both stacker paths now drain per output frame, and
`bakeExportFrame` drains itself since the Kit hook is public. After the
fix the real app peaks at 1.9 GB and holds flat at 1.19 GB for the rest of
the render, with byte-identical output. **The lesson for any future hook
on this loop: anything Core Image, Core Graphics or Foundation-object
shaped that runs per output frame must be inside that pool.**

**Overlays travel now (same day).** `overlays.json` is a top-level file,
and the only import allowlist was of SUBfolders, so an AirDropped project
arrived with its text gone. The archive always contained it —
`DirectoryArchive` writes the whole project folder — so only the installer
was dropping it. `ProjectArchive.transferableFiles` is the file-shaped
twin of `transferableSubfolders`, read by the installer and the transfer's
file manifest alike; archives made before the fix restore their text on
re-import.

## Adversarial review pass (same day)

A four-dimension review of the spike commit (concurrency, rendering,
model management, UI state) with adversarial verification confirmed ten
defects, all fixed in the follow-up commit: mask fetches now honor
cancellation between frames (abandoned sequence votes no longer pile up on
the actor); `maskFetchTask` snapshots its inputs with the cache key and
re-verifies the key after the debounce (a mode flip or scrub step during
the sleep could cache the wrong mask under a key — permanently, on disk);
the raster cache got a byte budget (costs were inert without
`totalCostLimit`; 24 × 12 MB rasters was jetsam bait); the morphology chain
is `clampedToExtent` like the feather (border erosion to black); the debug
tint skips the edge-bias erosion (it biases whichever region *restores*, so
the tint showed a different boundary than segmentation produced);
coreml snapshot validation requires all three package files (the downloader
fetches `weight.bin` before `Manifest.json`, so an interrupted download
validated as installed but couldn't compile) in both `snapshotDirectory`
and `locate`; deleting the model purges its compiled `.mlmodelc` from
Caches; the Frames tab gates on the UNFILTERED frame count (gating on the
filtered count reintroduced the documented bad-frames one-way door);
`finishExit`/`onDisappear` persist overlays (typed text's only mid-session
commit was the 2 s safety net, which dies with the view); and
`persistOverlays` no-ops when unchanged (a stale second window on the same
project could otherwise delete the sidecar another window just wrote).
Two further claims were refuted on verification (cooperative-pool
starvation — bounded to one thread by the actor; main-thread key-building
cost — measured at 68 µs).

## Traps hit / worth remembering

- `CatalogModel.isBuiltIn` was `engine != .mlx` — a `.coreml` entry would
  have been classified built-in and silently skipped the entire download
  machinery. Now `engine == .visionFramework`, plus `tagsScenes` so the
  segmentation model can never be adopted as the active tagging model
  (adoption, deletion fallback, factory, and the AI Models radio all
  filter on it; its row shows an "Editor" badge instead).
- `snapshotDirectory` validated `config.json` + safetensors — engine-aware
  now (`.coreml` accepts an `.mlpackage` whose `weight.bin` landed).
- Synthetic AppleScript clicks do not drive SwiftUI `DragGesture`s — the
  scrub and the overlay drag needed real CGEvent down/drag/up sequences
  (bench tooling note; `driver.py click` is fine for buttons/toggles).
- zsh does not word-split unquoted variables — a harness invocation with
  `$FRAMES` silently became one argument.
- `sips` cropping: `-c H W` then `--cropOffset y x` (row-major).

## Owed / follow-ups (also in TODO.md)

Export baking (all paths + gating), VideoEditorView overlay rendering, iOS
pass, overlays promotion into `CaptureProject` + `transferableSubfolders`,
draggable range handles, SegFormer-B0 probability upgrade, detail-patch/
loupe overlay parity, SVG mirrors for the tabbed rail (six iOS viewer SVGs
+ first `macOS/photo-viewer.svg`), and a SceneMasks entry on the storage
card's cache-clearing path.

## Reproduce

**Plain Xcode — no driver, no hooks, no env vars.** The shared LetsLapse
scheme carries no environment variables, so the whole feature is
self-serve from ⌘R (verified end-to-end 2026-08-31 on a plain launch):

1. Run the LetsLapse scheme (My Mac).
2. Settings ▸ AI Models ▸ **DETR Segmentation → Download** (85.5 MB, once
   per machine — the row moves to "On this device" with an *Editor* badge;
   it never becomes the active tagging model, by design).
3. Projects ▸ any interval or photo project ▸ **Edit** ▸ **Text** tab.
   Everything in this report is reachable from there. Skipping step 2 just
   disables Intelligent Placement — the panel says so and text works fully.

Bench conveniences (optional, DEBUG builds only): `LL_EDITOR=<capture-uuid>`
opens the editor on a specific project from the command line;
`LL_SEG_MODEL=<path>` loads a model file directly, and a snapshot can be
hand-placed under
`~/Library/Application Support/Models/detr-semantic-f16/models--apple--coreml-detr-semantic-segmentation/snapshots/<revision>/`.
`driver.py mac` wraps launch+screenshot for agents. None of these are
required for anything.

Mask-quality harness (standalone, no app):

```
swiftc -O LetsLapse/tools/seg_harness.swift -o /tmp/seg_harness
/tmp/seg_harness describe <model.mlpackage>
/tmp/seg_harness run <model.mlpackage> <outdir> <frames...>
```

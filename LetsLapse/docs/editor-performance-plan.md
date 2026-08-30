# Editor performance — sliders, scrubbing, and the render loop

**Date:** 2026-08-29 · **Trigger:** grading sliders (temp/tint/exposure/
highlights/shadows…) in the photo editor are sluggish on the iPad Air M3,
horrible on the iPhone 16 Pro, and deathly on the iPhone 12 Pro. Grabbing a
slider takes multiple attempts; a drag catches up seconds later. Same family
of complaint for editing blended clips (video editor).

**Status (2026-08-29 evening): stages 0–3 landed and measured on the Mac
bench, plus the sibling audit's progress-storm gate.** The
`LL_PERFWIGGLE` instrument (60 Hz slider-tick bursts through the panel's
own binding, on the seeded 1,480-frame project):

| build | ticks in 40 s | median burst rate | main-thread profile |
|---|---|---|---|
| baseline | 93 | **4.8 /s** | body eval dominated by `visibleFrameURLs` → `URLByAppendingPathComponent` → **one `getattrlist` syscall per frame URL**; `persistLibrary`/`JSONEncoder` per settle |
| stage 1 | ~1,460 | **~44–58 /s** | URL machinery gone; `persistLibrary` now the top app symbol |
| stages 2+3 | 1,482 | **58.4 /s** (16 ms sleep floor ≈ 60 ceiling) | `appendingPathComponent` 4 samples, persist encode off-main (11-sample snapshot residue), scratch alloc churn gone, 0 render failures |

**On-device A/B, iPhone 16 Pro, 2026-08-29 evening** — Debug-vs-Debug,
same phone, Steven's real library (260 captures, the 1,250-frame shoot the
`LL_EDITOR` hook auto-picks), hands-free over `devicectl --console` with
`DEVICECTL_CHILD_` hook env; the "before" built from HEAD in a throwaway
worktree with only the bench hooks injected:

| build | ticks in 40 s | median burst rate |
|---|---|---|
| HEAD + hooks | **5** | **0.2 /s** — one slider update every ~5 s |
| stages 1–3 + gate | **1,532** | **57.7 /s** |

~290×, zero render failures in either run. The 16 Pro's "horrible" feel was
the 260-capture manifest persist per settle stacked on the per-tick frame
window rebuild — both now gone.

Landed in this pass: stage 1 (stored frame window + `isDirectory: false`
in `sourceFrameURLs` — the syscall fix benefits every caller), stage 2
(gesture-end persist + off-main size-cache-preserving manifest write +
`flushLibraryPersists()` on editor exit), stage 3 (`restage(recipe:
reference:)` in the Kit, size-keyed renderer pool in `PhotoGrader`,
`MediaWorkQueue.grading` 1-wide render lane), and — pulled forward after the
2026-08-29 16 Pro screen recording of a blend start freezing mid-transition
for ~a minute — the **10 Hz gate on `reportClipProgress`/
`reportTailProgress`** (the sibling audit's P1 item 1). Kit grade tests
14/14; macOS and iOS builds clean. Owed: on-device before/after (the iPad
live-trace protocol), stages 4–6, and one oddity noted during benching —
before the wiggle one-shot guard, **two `PhotoViewerView` instances ran the
load task for one `LL_EDITOR` window** on macOS (two DONE lines, distinct
tick counts); if Mac editor windows ever behave doubled, start there.
Bench droppings that persist on this Mac: the seeded "Perf bench 1480"
project in the library, `LL_EDITOR`/`LL_PERFWIGGLE` DEBUG hooks, and the
bench harness in the session scratchpad (`bench.sh`, seeders, samples).

**Processing-flow pass (2026-08-29 late evening), from the 18:34 16 Pro
screen recording** (Create → 13 s frozen mid-transition composite → ghost
layers to ~55 s → Cancel unpressable): four fixes landed —

1. **Hero once per run**: `ProcessingView`'s hero resolved `mediaURL →
   source(for:)` in its body — a `fileExists` per source frame, per progress
   tick (~12k stats/s on the recorded shoot). Now resolved once in
   `startProcessing` onto the progress model.
2. **`ProcessingProgressModel`** (sibling P1.2): `progress`,
   `processingETADate`, `processingFramesDone/Total` moved off `AppModel`
   onto a processing-only observable (forwarding accessors keep the 45 write
   sites unchanged; `processingPhase`/`statusMessage` stay on AppModel — low
   cadence, the flow chrome reads them). App-root watch publishing moved
   from `onChange` to `onReceive` of the new publishers.
3. **Existence tickets**: `source(for:)`'s per-frame walk runs once per
   capture per session (`validatedSourceFrames`), cleared beside the size
   cache in `persistLibrary` (grade writes clear neither). Plus
   `isDirectory: false` on its URL building.
4. **Orchestration off main + `.utility` workers**: the sidecar load and
   `IntervalWarp.compile` inside `blendTask` (which inherits the main actor)
   now run detached; the stills/stack/slice spawns and `VideoBlender`'s
   queue dropped `.userInitiated` → `.utility`, so a minutes-long render
   sits below touch handling. Trade: blends may run somewhat longer on a
   loaded system; the win is a device that answers.

**Mac A/B** (`pbench.sh`, sampling t=3–23 s of the same blend, same
project): main thread **100% busy → 6% busy** (11,507/11,507 → 882/13,589
samples); AG graph updates 5,400+ → ~267; `ProcessingView →
source(for:preferring:)` and persist/JSONEncoder branches gone. Symbolicate
`sample`'s `???` frames with `atos -o …/LetsLapse.debug.dylib -l <load
addr>` when a killed process leaves them unresolved. Bench lessons: the
`LL_ADJUST=stills` pick is the NEWEST qualifying capture — the Mac library
now holds real transferred projects, so both legs blended "Overheat 1" (a
few bench blends registered there — delete when convenient) rather than
the seed; and a CPU-threshold start gate misses `.utility` runs — sample on
a fixed timer.

**On-device 16 Pro A/B (2026-08-30 morning)** — same hook-launched blend of
the real 1,249-frame DNG shoot, 25 s Time Profiler attach each side
(`DEVICECTL_CHILD_LL_ADJUST=stills DEVICECTL_CHILD_LL_ADJUST_CREATE=1`,
then attach by PID — attach-by-name races the process registry):

| build | main-thread share of samples | ≈ main-thread CPU in 25 s |
|---|---|---|
| pre-fix (installed) | 3,681 / 24,417 (**15%**) | ~3.7 s |
| fixed | 877 / 25,525 (**3.4%**) | ~0.9 s |

4.2× less main-thread work — and the comparison is biased against the fix:
the before-attach was delayed past the launch wedge (steady-state storm
only), while the after window included the launch phase. The wedge window
itself is the Mac A/B's symbolicated 100% → 6%. The after build's residual
main-thread frames are benign (AG upkeep, GPU encoder, objc runtime).
Export notes: the before trace's `time-profile` table never analyzed
(deferred mode) — the raw `time-sample` table exports regardless and both
sides were counted on it; its backtraces are unsymbolicated addresses, so
name-level proof rides the Mac sample + the after trace's `time-profile`.
The fixed build is left installed on the 16 Pro.

**Sibling audit:** [perf-audit-2026-08-29.md](perf-audit-2026-08-29.md)
(same day) found the *render-progress* `@Published` storm on `AppModel`. This
document is the second storm of the same family — the editors' own loop —
and its measured 12 Pro trace independently caught this document's finding 2c
(`AppModel.source(for:preferring:)` + URL/String building as the top
main-thread frames during list invalidation). The two plans share one root:
object-level `ObservableObject` invalidation on a monolithic `AppModel`, plus
O(frames) work inside view bodies. Fixes are coordinated below (stage 6).

**Why the M3 iPad is slow too:** none of the mechanisms below is
compute-bound. They scale with **shoot length × slider-tick rate** (main
thread) and **library size** (persistence), not with silicon. The iPad's real
projects are 1,480 / 1,304 / 908 frames (pulled manifest); the 12 Pro holds a
2,866-frame shoot. Photo-mode (single-still) captures skip the frame-list
machinery entirely, which is why the pain is specifically interval projects.

---

## Verdict — mechanisms, ranked

### 1. O(frames) main-thread work on every slider tick

`PhotoViewerView.frames` (`App/PhotoViewerView.swift:232`) is a computed
property that calls `AppModel.visibleFrameURLs` (`App/AppModel.swift:1263`)
→ `sourceFrameURLs` (`:1146`), which **filters and re-constructs a `URL` for
every frame of the shoot on every access**. `frameSeconds` (`:249`) re-zips
and re-filters `allFrames`/`allFrameSeconds` the same way; `frameAxis`
(`:285`) is rebuilt from both. **Measured: 10.9 ms per call at 1,480 frames
on the M4 Max** (compiled `-O`; `URL.appendingPathComponent` dominates).

The body touches these on the order of a dozen times per evaluation — the
render-request `task(id:)` (`:540`, `frameIndex` → `frameAxis` →
`frameSeconds`), `patchRequest`/`loupeRequest` ids (`:1466`, `:1501`, via
`displayedURL` and `gradeToken`), `timelineStrip` → `timelineLabel` →
`frameSeconds` (`:314`), two `stepControl`s → `frameIndex` (`:398`),
`hasTimeline`, `currentFrameFileName`, the bad-frame rows. And the body
**does** re-evaluate per tick: the slider binding's set writes `adjustments`
and `presetState` `@State` (`:1166`, `refreshState` at `:1334`), both read
during body construction. At 60–120 Hz tick rate that is
**100–200+ ms of main-thread work per tick on the iPad, several× worse on
the A14** — a saturated main thread drops touch-downs, which is exactly
"can't grab the slider". Every access also runs `capture` (`:195`), a linear
search of `model.captures`.

### 2. Every debounced settle persists the whole library and invalidates the whole app

Each ~100 ms pause in a drag (`renderDebounce`, `:193`; video editor 150 ms)
runs `persist()` (`:1351`) → `setPhotoGrade` (`App/AppModel.swift:7452`) →
`write` (`:7467`) → `persistLibrary()` (`:6176`), which:

- **(a)** JSON-encodes the **entire manifest** — every capture's
  `sourceFileNames` included — with `.prettyPrinted, .sortedKeys` (the slow
  options) and writes it atomically, **synchronously on the main actor**.
  276 KB today on the iPad; grows with the library.
- **(b)** clears `projectStorageBytes` for **all** projects (`:6179`) even
  though a grade write changes no file sizes — so the next time any size
  label appears, a recursive folder walk re-runs per project on the shared
  media queue (`:3812-3820`).
- **(c)** mutates `@Published captures` → object-level invalidation of every
  screen observing `AppModel`: all five tabs stay mounted in the `TabView`
  (`App/LetsLapseApp.swift:964-996`), plus `ProjectDetailView` under the
  cover, plus the editor itself. Two documented consequences:
  - `ProjectDetailView`'s hero pane re-keys on the grade's `cacheToken`
    (`App/ProjectDetailView.swift:1539`, 100 ms debounce `:1481`) and fires
    a **second full render at 1400 px** (`:1744-1758`) on the same queue as
    the editor's preview — every settle renders the grade **twice**. In the
    video editor the hidden render is an `AVAssetImageGenerator` decode
    (`App/VideoGrader.swift:38`), heavier still.
  - List/detail bodies re-resolve media through
    `mediaURL → source(for:)` (`App/AppModel.swift:1124`, `:6052`), which
    runs **`FileManager.fileExists` for every source frame** of a photos
    project (`:6063-6065`) synchronously on the main actor — ~1,480 stats
    per visible card per settle. This is the exact hot stack the sibling
    audit's on-device Time Profiler caught.

### 3. Every preview render allocates ~60 MB of Metal scratch and throws it away

`PhotoGrader.engineRender` (`App/PhotoPreset.swift:291`) calls
`engine.makeRenderer(…)` per render; the fresh `GradeRenderer` allocates its
full scratch set on first `encode` — two full-size `rgba16Float` textures
plus quarter/half-res planes (`Kit/…/Grading/GradeEngine.swift:555-588`,
~60 MB at 2000 px) — then the renderer is discarded. `restage()`
(`GradeEngine.swift:186`) exists precisely to avoid this and the blend path
uses it; the preview path doesn't. Cost: allocation latency per render plus
memory churn — and memory pressure on the A14 empties the `NSCache`s, which
forces re-decodes at the worst moment.

### 4. Renders queue behind zombie renders and library housekeeping

All grade previews, thumbnail decodes, folder-size walks and the hero's
hidden render share one 2–4-wide `MediaWorkQueue`
(`App/MediaWorkQueue.swift:59`). Cancellation is only checked **before** a
job's body starts (`:81-87`): once a render is running, cancelling the
awaiting task resolves the continuation but the render itself runs to
completion, holding a slot. Under a drag, stale renders occupy the width
while the one that matters queues — "the drag catches up seconds later".
Finding 2b's size-walk re-triggers land on the same queue.

### 5. Scrubbing an interval shoot is a RAW decode per step

Sources are ~10 MB 4032×3024 DNGs; each new frame under the playhead is a
`CIRAWFilter` decode (`Kit/…/Grading/LinearFrameDecoder.swift:136`), order
of a second each, against a 3-entry decoded cache
(`App/PhotoPreset.swift:240-247`). The scrub ladder (`PhotoViewerView.swift:436`)
caps requests at 60 positions, but each position is still a full decode.

**Cleared, and one booby trap:** the WB sliders do *not* re-decode on
Steven's devices — `decodeToken` (`App/PhotoPreset.swift:416`) couples the
decode cache to `temperatureMired`/`tint` **only under `.cirawFilter`**, and
both the iPad and the 12 Pro run the default `.bradfordAdaptation` (verified
by pulling `Library/Preferences/com.regularsteven.letslapse.plist` from both
devices — no `rawDecodePath` key). If the Settings picker ever moves to
"Core Image RAW", every temp/tint tick becomes a full re-decode — for
**every** source type, JPEG included, because the token keys on the path
*asked for*, not the path that applies. Worth an in-editor guard one day.

### 6. Video editor: pipeline restart per settle

Each 150 ms settle swaps a **fresh** `AVMutableVideoComposition` onto the
live player item (`App/VideoEditorView.swift:190-196`, `applyGradeToPlayer`
`:757-761`) — AVFoundation reconfigures its render pipeline mid-drag — on
top of the same finding-2 persist. While the clip plays, a 30 Hz main-queue
time observer (`:514-523`) drives SwiftUI invalidation throughout.

---

## macOS applicability — yes, all of it

Every file above compiles into the Mac target unchanged. Differences of
degree, not kind:

- The photo/video editors are their own windows on macOS
  (`PhotoEditorWindowRequest` scene), with `ProjectDetailView` still visible
  in the main window — so finding 2's "hidden" hero render is *visible* on
  the Mac (arguably a feature; still a second render per settle on the same
  queue).
- The Mac's `Slider` is just as continuous; body-per-tick and the O(frames)
  properties cost the same 10.9 ms/call — measured **on this Mac's own
  silicon**. A dozen calls per tick saturates one core at display cadence
  exactly as on the iPad.
- The Mac library is currently empty (`~/Library/Application
  Support/LetsLapse/Projects`), which is why none of this has been felt
  there. Seed a real-scale project and it will be.

The Mac is therefore the right fix bench: same defects, fastest
build-measure loop, no devices tied up, and every fix lands on iOS for free
because the code is shared.

---

## Fix plan — staged, Mac-first, each stage gated by measurement

### Stage 0 — bench harness on this Mac

1. **Seed** a synthetic interval project at real scale: 1,480 small JPEGs
   (~1920 px, generated) under `Projects/<uuid>/source/`, plus a manifest
   entry lifted from the iPad's pulled `library.json` (schema in hand), two
   `nominatedBadFrameNames` to exercise the filter path. JPEG keeps decode
   cheap so main-thread effects isolate cleanly; a second DNG-sourced
   project (copied off a device once) covers stages 3–4.
2. **Drive**: unsigned Debug build, `LL_DETAIL=latest` to land on the
   project, open the editor, drag sliders via AX (the `axdrive` recipe) —
   repeatable ~30 s drag choreography.
3. **Measure**: `sample`/Time Profiler on the drag window; a DEBUG
   `os_signpost` pair around body evaluation and around
   `persistLibrary` if symbol attribution proves too coarse. Record a
   baseline trace before touching anything.

### Stage 1 — kill the O(frames) body work (finding 1)

Editor-local caching, no engine changes, no behaviour changes:

- Make `frames`, `frameSeconds`, `frameAxis` **stored** `@State`, derived in
  one place; recompute only when their true inputs change: `allFrames` /
  `allFrameSeconds` (load), the nomination set, and the hide toggle —
  a single `refreshFrameWindow()` called from the load task and an
  `.onChange` keyed on `(capture.nominatedBadFrameNames, capture.hideBadFrames)`.
- Resolve `capture` once per change of `model.captures` rather than per
  access, or narrow the editor's reads so a captures publish doesn't imply a
  full re-derive.
- Leave `AppModel.visibleFrameURLs` itself alone for now (its other callers
  are event-driven); the editor is the only per-tick caller.

**Gate:** during a 30 s drag on the 1,480-frame seed, zero
`visibleFrameURLs`/`appendingPathComponent` samples on the main thread;
parent body evaluation sub-millisecond.

### Stage 2 — persistence discipline (finding 2)

- **Persist on gesture end, not per settle**: the panel already reports
  grab/release (`onFieldEditing`, `PhotoAdjustmentsPanel.swift:273`); write
  through to the model at slider release, chip apply, keyframe ops,
  playhead-driven keyframe writes, and `finishExit` (already there). During
  the drag the editor's own `@State` remains the single live surface — the
  preview keeps rendering per settle from local state, but the model (and
  therefore the whole app's view tree, the hero's double render, and the
  stat storms) is touched once per gesture.
- **Split `persistLibrary`**: grade-only writes must not clear
  `projectStorageBytes` (sizes didn't change); encode+write moves off-main —
  snapshot the value-typed manifest, encode on a background task, serialize
  latest-wins so concurrent writes can't interleave. Whether
  `.sortedKeys/.prettyPrinted` stay is then irrelevant; keep them for
  diffability.
- Video editor: same gesture-end persist; its composition swap moves to
  stage 5.

**Gate:** exactly one `persistLibrary` per drag gesture, none on the main
thread; hero pane renders once per gesture; no `fileExists` storms during a
drag. Sign-off note: on macOS the visible hero now updates on release rather
than live — Lightroom behaviour, flag it in the stage's check-in.

### Stage 3 — render lane: serialize, coalesce, reuse (findings 3–4)

- A dedicated **1-wide render lane** (own `MediaWorkQueue` instance or a
  small actor) for editor preview/patch/loupe renders, separate from
  browsing I/O. Latest-wins: a new request replaces the queued one; at most
  one render in flight, so zombie renders stop occupying the browse queue
  and the newest grade renders next, always.
- A **persistent `GradeRenderer`** held by `PhotoGrader` for preview-scale
  renders, `restage(recipe)` per render — the lane's serialization satisfies
  the renderer's single-driver contract. Keyed by texture size (fit vs
  scrub sizes both recur); `renderForBlend`/exports keep making their own.
- Keep `MediaWorkQueue` for thumbnails/sizes; consider `.userInteractive`
  QoS on the lane.

**Gate:** Metal allocation trace shows no scratch allocation after the first
render of a size; drag catch-up (last tick → final preview on screen)
< 300 ms on the Mac seed; browse-queue depth unaffected by dragging.

### Stage 4 — scrub decode cost (finding 5)

- Raise the decoded-frame cache to ~8 entries cost-bounded (still well under
  the 220 MB ceiling at preview scale), and decode-ahead the two neighbour
  ladder positions during an active scrub on the render lane's idle time.
- Drop the live-scrub render edge from 1100 px further (≈800 px) — it's a
  moving image under a thumb.

**Gate:** scrubbing back across the cached window is decode-free; forward
scrub sustains several frames/s on the DNG seed project on this Mac.

### Stage 5 — video editor stops restarting the pipeline (finding 6)

- Build the composition **once** per player item with a handler that reads
  the current grade from a small lock-protected box; slider changes update
  the box — no composition swap, no pipeline restart. Swap only on the
  identity ↔ non-identity transition (the `nil`-composition case).
- Gesture-end persist from stage 2 applies here too. Optionally pause the
  30 Hz observer's `position` writes while a slider is being dragged.

**Gate:** composition object identity stable across a drag; graded playback
continues uninterrupted while sliders move.

### Stage 6 — the structural fix (coordinated with the sibling audit's P1)

The shared root: one monolithic `ObservableObject` with object-level
invalidation. The sibling audit already plans a `ProcessingProgressModel`;
this stage is the editor-side counterpart and the longer arc:

- Cache/async the `source(for:)` existence checks for list rows (hot in the
  measured 12 Pro trace) — an existence cache keyed per capture, invalidated
  by file-mutating ops only.
- Evaluate migrating `AppModel` to `@Observable` (the app floor is already
  iOS 17 / macOS 14 since the MLX work): per-property read tracking makes
  captures churn invalidate only views that read captures, retiring the
  whole invalidation-storm class. Big, separate job — raise it in TODO.md
  when stages 1–5 have landed and been felt on device.

### Sequencing and verification on iOS

Stages 1–3 are the felt fix and land together as one arc; 4–6 follow.
After the Mac gates pass, the before/after on device is the already-prepared
iPad session: Time Profiler attached while Steven drags sliders on the
1,480-frame project (baseline can be captured before the fixes install —
worth doing so the win is a measured number, not a feeling). The 12 Pro's
2,866-frame project is the stress case.

**Traps to respect while implementing:**
- `GradeRenderer` is explicitly not thread-safe — reuse only behind the
  serial lane.
- The editor's `finishExit` persists synchronously on the way out — keep
  that ordering ahead of `dismiss()` when persist goes async (a fire-and-
  forget write racing app termination on macOS window close would lose the
  last gesture).
- Keyframed writes (`GradeTimeline.write`) mutate baseline + timeline per
  tick in local state; gesture-end persist must capture both.
- `LL_KEYFRAMES`/`LL_VIEWER` hooks and the fullscreen sheet's embedded
  editor (`showsBackButton: false`) share these paths — re-check both after
  stage 2.
- `NSCache` empties under memory pressure; stage 3's persistent renderer
  must tolerate a purged decoded-frame cache mid-drag (it already re-decodes
  through `decodedFrame`).

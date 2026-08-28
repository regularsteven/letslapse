# Time slicing — implementation plan

**Raised:** 2026-08-28 (developer brief, same date) ·
**Status: stages 1–4 + the verifier landed 2026-08-28 (Mac-only, per the
sequencing decision); stage 4's UI awaits Steven's sign-off → then the SVG
mirrors; stage 5 (processing loader) not started**

*Stage 4 (Adjust UI, code-first per the standing decision) landed the same
day and was screenshot-verified on the Mac build: a `Time slicing` card
between Advanced and the Create bar in all four layouts — toggle row carrying
the recipe name, Horizontal bands, Newest edge (segmented, axis-aware
labels), Segments and Offset steppers (offset shows the derived capture-time
per band), Output Image/Animation/Both, Include regular timelapse, and the
live readout (spread in frames ≈ clip seconds · sliced length with the trim
stated · poster line · scratch estimate — the 12 MP case reads the same
~1.1 GB the real run measured). Refusals (sub-2 px bands, spread ≥ clip)
render red and disable Create; the CTA reads "… + slice" / "Create sliced
clip" / "Create time-slice poster" by what the run will keep. Session stash
keeps entered values across an off/on toggle. Mirrors owed after sign-off:
`iOS/adjust.portrait.svg`, `iOS/adjust.photos.portrait.svg` (already stale),
a new `adjust.timeslice` state, INDEX rows — plus the stage-3 project-detail
copy debt.*

*Stage 3 (app orchestration) landed and E2E-verified on the real Mac library
the same day: the slicer runs as the last tail pass in `startProcessing` —
after `RenderVerifier`, detached off the main actor with Cancel bridged onto
the renderer — and one Create registered three blends on the newest dawn
shoot: the regular 350-frame clip (no recipe), the 329-frame sliced animation
(350 − the 21-frame spread, exactly) and the poster, both carrying
`timeSlice` in the manifest and named by the recipe. Also in: the `slicing`
`ProcessingPhase` (checklist row unchanged — it maps to Encoding; the phase
label says "Time slicing..."), a real `sliceBand` in `BlendProgressPlan`
(squeeze-everything-before-it, ~15% of the bar), `openBlend` rehydration,
temp-master cleanup when the regular clip isn't kept, poster EXIF/GPS
carryover from the first source frame, and the `LL_TIMESLICE` launch hook
(`"segs:8,lag:3,newest:left,output:both,regular:on"`, pairs with
`LL_ADJUST_CREATE`). Mirror debt (stage 4's pass): sliced rows'
`versionTitle`/badge copy in project detail.*

*Landed on `ios-app`: `Kit/Sources/LetsLapseKit/TimeSlice.swift` (settings,
geometry, ladder — 17 tests) and `TimeSliceRenderer.swift` (provider protocol,
`AssetFrameProvider` with an exact compressed-pass frame count, the band-spool
ring file, poster composite, display-edge mapping through the master
transform — 8 tests, all measured against synthesized clips), `lapse slice`
in the CLI, and `tools/timeslice_report.py` — which independently re-measured
rendered slices' ladders at exactly the commanded slope with zero residual
(`TIMESLICE PASS`), and answers `TIMESLICE INCONCLUSIVE` rather than a false
FAIL when a flat scene gives the luma measurement nothing to grip (the audit
needs global luminance change — a day-to-night shoot, the feature's real
subject; on static scenes the Kit tests and the poster's own content carry
the verification). Real-footage E2E on this Mac: the 1,587-frame 12 MP
"Blended 10 long" library blend sliced at the reference defaults in
**72.6 s at 265 MB peak footprint** — the flat-memory design measured true
against a ~1.1 GB cycling spool — and its full-source poster shows the tram
sliced mid-crossing across the bands.
Two traps for the record: a passthrough `AVAssetReaderTrackOutput`
interleaves zero-sample marker buffers among the real samples, so an exact
frame count sums `CMSampleBufferGetNumSamples` rather than counting buffers;
and `FileHandle.read`'s autoreleased Data made the spool loop's memory track
bytes read 1:1 until the OS killed it — the project-transfer pump's exact
bug, fixed the same way, with a per-frame `autoreleasepool` that is
load-bearing, not hygiene.*

Time slicing partitions the output frame into N bands, each sampling a different
point on the source timeline, so the time gradient scrolls across the frame
during playback — a sunrise arrives at one edge and travels to the other. The
single-frame variant is the classic "whole day in one photograph" poster. It is
a **sampler**, not a compositor: it selects which already-rendered blended frame
each band reads from and generates no new pixel values. Scope: Interval and
Video shoots, inside `+ New blended clip`. Photo shoots, feathered edges,
non-uniform/radial bands and the per-pixel displacement map are out of scope for
this phase (brief §6).

Reference behaviour, measured from `segments.mp4` (London skyline, 720×1280,
~6.6 s): **24 vertical bands** of exactly 30 px, **hard cuts**, a dead-straight
linear lag ladder of **2 frames per band** (total spread 46 frames ≈ 1.9 s),
newest band at the left, and **no clamping at either end — the source ran longer
than the output by exactly the spread.** That last measurement matters: the
reference clip's "end policy" is what §4 below calls *trim*.

This document supersedes two parts of the 2026-08-28 brief where the codebase
contradicted it: the memory model (§1) and the placement of stage 1.5 (§2).

---

## 1. The correction that shapes everything: §4.7 of the brief is wrong

The brief claims that because "only one band of each historical frame is ever
read" per output frame, a ring buffer can retain *bands, not frames* and total
one frame's worth of pixels. That is true **only for the single-frame poster**.
For the animation it does not survive arithmetic:

With ladder `lag[j] = j·o` (S bands, offset o, maxLag = (S−1)·o), output frame
`t`, band `j` shows master frame `m = t + maxLag − lag[j]`. Invert it: master
frame `m` is read by band `j` at output `t = m − maxLag + lag[j]` — **a
different band at each of S distinct output frames across m's whole
maxLag-frame lifetime.** Every band of every frame is eventually consumed.
Retention floor for any single-pass drop-after-read scheme ≈ **half the spread
in full-frame equivalents**: at the default 24×2 (spread 46) that is ~23 frames
— 4K BGRA ≈ 760 MB, 4K biplanar YUV ≈ 285 MB, and the spread is user-scalable
upward. A naive full-frame ring is (maxLag+1) frames: 1.55 GB at 4K BGRA. None
of that belongs in an iOS process that already fights jetsam on long shoots.

**The design that actually achieves flat memory is a banded strip spool on
disk** (§3.3): the same "bands, not frames" instinct, executed at the layer
that can afford it. The poster keeps the brief's O(1) claim intact — one
composite frame, each master frame contributing exactly one band as the
sequential pass crosses its ladder position.

---

## 2. Architecture: stage 1.5 is the *last tail pass*, not an in-loop tap

The brief places the slicer "downstream of the blend, upstream of encoding,
with access to full-resolution blended frames." Four facts from the code say
the pre-encoder seam is the wrong place:

1. **Blended frames are not uniform there.** A mixed-resolution ramp shoot
   (1080p base + 4K bursts) blends each segment in a *separate* `VideoBlender`
   run at its native size ([AppModel.swift:4535](../App/AppModel.swift)); uniformity is imposed
   afterwards by `SegmentNormalization` → `normalizedSegment` (crop-before-
   shrink to the base-derived render size) and the `stitchVideos` composition.
   A tap at the adaptor `append` would see per-segment sizes — exactly the
   §4.8 straddling problem, unsolved.
2. **There are four engines to tap, not one.** `ImageStacker.stackSequence`,
   `stackSequenceLinear`, `VideoBlender`, and `MacVideoJobRunner` — and the Mac
   runner blends its windows **concurrently and out of order** (filename-sorted
   afterwards), so an ordered streaming tap is structurally impossible there.
   `ImageStacker` also has no cancellation to inherit.
3. **Geometry and grade land after the blend.** Canvas crop, punch-in reframe
   (Lanczos, per-output-frame) and the grade bake — including the *keyframed*
   grade — are all tail passes over the finished intermediate. A band must
   carry the geometry and the grade of **its own source moment**, which only
   exists after those passes. Slicing before them samples the wrong pixels.
4. **The precedent is already paid for.** The reframe is documented as "a
   second full export" over the H.264 intermediate; `CompositionExporter` is an
   existing reader→writer tail pass. Slicing from our own just-rendered master
   is the same fidelity class the reframe already accepts.

**Decision:** stage 1.5 consumes the **finished blended clip** (post normalize/
stitch/reframe/canvas/grade — the file that today goes straight to
`storeBlend`), through an `OrderedFrameProvider` abstraction whose v1
implementation is a sequential `AVAssetReader` over that file.

What this buys, beyond correctness:

- **§4.2's "extend the blend pass" pressure disappears** for the common case —
  the master already covers the whole source; the sliced animation is shorter
  by the spread, which is the reference clip's own behaviour.
- **The brief's §4.8 burst-resolution question dissolves** — frames are uniform
  by construction; the resolution that wins is the render's existing decision.
- **The parked §2.2 path ("re-slice an existing blended clip") becomes the
  same code** with the same provider pointed at a stored blend. Only its UI is
  deferred.
- **"Include regular timelapse" costs nothing when ON** — the master *is* the
  regular clip; the slicer reads it back. When OFF, the master renders to temp
  (candidate: force `hevcMain10` for the throwaway mezzanine — decision open,
  §9) and is deleted after.

Quality note against the brief's §4.8: this is not a proxy. The master is our
own full-resolution render at the user's chosen encode profile
(`h264High8Bit` / `hevcMain10` via the Create button's chevron); the compressed
generation between blend and slice is the identical trade the punch-in reframe
ships with today.

---

## 3. The sampler, precisely

### 3.1 Indexing

For sliced output frame `t` and band `j` (j = 0 is the **newest** band, at the
edge the Direction control selects):

```
master(t, j) = t + maxLag − lag[j]        lag[j] = j × offsetFrames (linear)
maxLag       = lag[S − 1]
outputFrames = M − maxLag                  (M = master frame count)
```

The ladder is built as an array up front (`lagLadder(settings:)`), never
computed inline, so eased/exponential distributions later are a new array, not
a new sampler. Direction reverses the band→j assignment, not the ladder.
"Rate" from the brief's control table is **not a slicer parameter**: slicing in
master-frame space means every band inherits its frame's compiled window —
blur, speed, grade — exactly as playback would (see Q5, §4).

**PTS carry.** Master PTS are not uniform (interval blends are timed on the
capture clock via `FrameTimeMapping.presentationSeconds`; warped clips on
`customWindowTimes`). Sliced frame `t` takes master frame `t`'s PTS verbatim —
pacing matches the master, duration ends `maxLag` frames early.

### 3.2 Band geometry

`TimeSliceGeometry.bandRects(axisLength:segments:)` — pure, Kit, unit-tested:

- Remainder distributed across bands Bresenham-style (1080÷24 = 45 exact;
  1920÷7 = 274/275 interleaved), never a runt band at one edge.
- Band boundaries **rounded to even pixels** on the sliced axis when the
  working format is 4:2:0 (chroma siting), the widths re-balanced after.
- Validation: reject segment counts producing sub-2 px bands against the
  clip's real output size (known in Adjust via `VideoCanvasCropper.cropSize` /
  the render summary).

### 3.3 Memory: the banded strip spool

One sequential decode pass; flat RAM; bounded, preallocated disk.

- Decode master frames `m = 0…M−1` in order (`AssetFrameProvider`, requesting
  the decoder's native biplanar 4:2:0 where the plane shape allows — the
  `VideoBlender.nativeBiplanar420Format` probe is the model — BGRA fallback).
- For each frame, cut its S bands. Band j = 0 is consumed immediately (it
  belongs to output `t = m`, emitted this iteration once `m ≥ maxLag`); bands
  j ≥ 1 are appended to **strip j** — a preallocated ring file of `lag[j]`
  fixed-size records, indexed modularly. Writes and reads are both sequential
  per strip; a record is dead the moment it is read.
- Emitting output `t = m − maxLag`: read record `m − lag[j]` from each strip,
  memcpy into the composite output buffer (from the writer adaptor's own
  pool), append with the carried PTS.
- **Disk bound:** Σ lag[j] × bandBytes = maxLag/2 × frameBytes. Defaults
  (spread 46): 1080p BGRA ≈ 190 MB; 4K YUV ≈ 285 MB. Precheck against
  `volumeAvailableCapacityForImportantUsage` (the `exportProject` /
  MacVideoJobRunner guard pattern), spool in the app temp directory, deleted
  in a `defer`.
- **RAM bound:** one decoded frame + one composite + the pools. Independent of
  spread, resolution, and segment count.
- Rejected alternatives, for the record: full-frame RAM ring (¶ §1 numbers);
  per-band staggered readers (S× decode on a decode-bound platform); the
  in-loop tap (§2).

**Poster:** no spool. One composite in RAM; as the pass crosses each of the S
full-source ladder positions it writes that band. Poster-only runs (Output =
Image) may instead seek the S frames via `AVAssetImageGenerator` with zero
tolerance — an optimisation, not a requirement.

### 3.4 Cancellation, progress, failure

- Cancel = flag + `Task` cancellation checked per output frame, VideoBlender-
  style; the spool teardown is the same `defer` as success.
- Progress: a real **`slicing` phase** in `BlendProgressPlan` and
  `AppModel.processingPhase` — not another pass borrowing the `grading` label
  (the documented §4.9 checklist gap; don't grow it).
- A slice failure discards sliced outputs only; an already-registered regular
  clip survives.

---

## 4. The brief's open questions, answered from the code

> **Confirmed by Steven 2026-08-28:** Q1 frames · Q2 trim ("this is how I
> would imagine this") · Q3 full-source poster · Q4 as high as possible with
> **no upscaling** (= the master's resolution, bands copied 1:1) · Q5 yes ·
> Q7 the attribute scheme, no `spread_full` token, poster file = **PNG**.
> Q6 was superseded by the processing loader (§6a) — the Adjust inline
> preview is dropped from this phase.

**1 · Offset units — store frames, display capture time.** The sampler and the
spool need a *constant integer frame ladder*; a wall-clock ladder over a warped
or variable-interval clip makes the frame-lag vary with `t`, which breaks the
fixed-retention invariant and re-opens unbounded buffering. The display side is
cheap and already built: per-output-frame source times exist for every path
(`WarpCompiler.frameSourceTimes` for video; `IntervalWarp` windows +
`FrameAxis` over `frames.timestamps` for stills — every interval-style run has
written the sidecar since 2026-08-24, legacy projects degrade to the uniform
axis). UI shows *"Offset 2 frames ≈ 12 s of capture per band"*, a min–max range
when a warp makes it non-uniform. Cost for Holy Grail/variable-interval: a
table lookup — not disproportionate. (This inverts the brief's recommendation,
deliberately.) Corollary the readout should own: on a warped clip the time
gradient stretches and squeezes with the warp — consistent with playback.

**2 · End policy — trim, one rule, said out loud.** A plain timelapse already
consumes the whole source, so "extend the blend pass" has nothing to extend
into in the common case. v1 rule: sliced animation = `M − maxLag` frames, and
the §6 readout states it before Create: *"Sliced clip 8.1 s — 1.9 s shorter
than the regular timelapse (the spread)."* This is exactly the reference
clip's measured behaviour. Refuse (Create disabled, message in the readout)
when `M − maxLag < 1`; amber the readout under ~1 s. Clamp and loop are not
built. Extend returns in v2 only where unused source really exists (video trim
active, warp not covering the source).

**3 · Poster spread — full source, as its own derived value.** Image output
spreads the ladder evenly over the entire master (S samples), shown separately
(*"Poster: full shoot · spread 2 h 04 m"*), independent of the animation's
offset, and `Both` uses the same rule — the still is never a grab from the
animation. No extra control in v1.

**4 · Burst-resolution straddling — dissolved by §2.** The slicer reads the
finished clip after `SegmentNormalization` and the stitch; frames are uniform
by construction and the winning resolution is the render's existing decision.

**5 · Speed ramps × rate — per-band correctness is automatic.** Constant lag in
master-frame space means a band shows master frame `m` with `m`'s own compiled
window: its blur, its speed, its capture moment, its keyframed grade. No
per-band rate evaluation exists to get wrong. "Rate" appears in the UI only as
the derived capture-seconds-per-frame line.

**6 · Preview — redirected (Steven, 2026-08-28).** Instead of an inline
preview in the Adjust section, the band-composite machinery becomes the
**processing loader** (§6a): every blend run's Processing screen builds the
project up segment by segment in place of the blurred hero. The Adjust inline
preview is out of this phase; the decode-cost facts and per-source strategies
move to §6a where they now apply.

**7 · Storage — sliced outputs are `BlendProject`s.** Animation =
`kind: .video`, poster = `kind: .image` (the existing `blends/<uuid>.png`
long-exposure pattern). Everything lives in `blends/`, so archive/transfer
(`transferableSubfolders`), import re-ID, storage buckets, rotate and delete
are inherited **with zero allowlist changes** — audited against all seven
integration points in the transfer/import map. `BlendProject` gains
`timeSlice: TimeSliceSettings?` (optional Codable — old manifests decode, no
schema bump, same precedent as `warp`/`reframe`). Naming: `versionTitle` gains
the variant *"Time-sliced clip N · 24 bands · 8 s"*, badge "Sliced"; poster
*"Time-slice poster"*. With *Include regular timelapse* ON, one run registers
**two** BlendProjects (regular + sliced), each independently re-editable via
"New blended clip from these settings" (`openBlend` rehydrates `timeSlice`),
deletable, and collectable; OFF registers the sliced output only.

**Naming (decided 2026-08-28, Steven):** the display name is derived from the
recipe in attribute form —

```
timeslice-{vert|horiz}-{left|right|top|bottom}-segs_{n}-lag_{n}
```

e.g. `timeslice-vert-left-segs_24-lag_2` — axis, then the edge holding the
newest band (left/right for vertical bands, top/bottom for horizontal), then
segment count, then lag **in frames**. Band width never appears; it is
auto-calculated (§3.2). The poster drops the lag (its spread is the full
shoot): `timeslice-poster-vert-left-segs_24`. On disk the file stays
`blends/<uuid>.<ext>` — the import re-ID loop rewrites `outputFileName` to a
fresh UUID, so an attribute file name would not survive a `.lapse` round trip;
the attribute string is the derived label (the `versionTitle` slot), and doubles
as the suggested file name at share/export time.

---

## 5. Model

`TimeSliceSettings` (Kit, `Codable`, all fields explicit so persistence never
churns as controls arrive):

```
axis          .vertical | .horizontal        (default vertical)
segments      Int                            (default 24)
direction     .newestLeading | .newestTrailing (default leading edge = newest)
offsetFrames  Int                            (default 2)
edge          .hard | .feathered(px)         (v1 renders .hard only)
distribution  .linear | …                    (v1 builds .linear only)
output        .animation | .image | .both    (default .both)
includeRegular Bool                          (default true)
```

App side: `AppModel.timeSlice: TimeSliceSettings?` `@Published`, reset by
`reset()`/`openCapture()`, rehydrated by `openBlend()`, snapshotted in
`startProcessing`, persisted on `BlendProject.timeSlice`. Nondestructive by
construction — parameters ride the recipe; the render reproduces from source.

---

## 6. UI

**Placement:** a `timeSlicingRow` disclosure in `AdjustView` between
`advancedRow` and the Create bar, in both the video and stills branches (and
both wide layouts) — the `reframeToggleRow` pattern: toggle off by default,
switching on expands the section in place, switching off collapses and keeps
the values for the session. Hidden when the source can't slice: single-image
outputs ("One long exposure"), photo projects (not in this flow anyway). The
guided builder does not get slicing in v1.

**Controls (v1):** Horizontal toggle · Segments · Direction · Offset (with the
live capture-time equivalent) · Output (Image/Animation/Both) · Include regular
timelapse. **Deliberately omitted until their second option exists:** Edge and
Distribution — a picker with one live choice is noise; the model carries both
fields from day one.

**Readout (the §3.4 contract from the brief):**

```
24 bands · spread 46 frames ≈ 1.9 s of clip (12 s of capture per band)
Sliced clip 8.1 s — 1.9 s shorter than the regular timelapse
Poster: full shoot · spread 2 h 04 m
Scratch ~190 MB — OK
```

Amber + explanation when trimming below ~1 s of output; Create disabled with a
plain refusal when the spread eats the clip (`M − maxLag < 1`) or bands go
sub-2 px; scratch line goes red when free space fails the precheck.

**Design-sync:** UI work starts with the standard question (design files first
vs app code first). Mirrors owed in the same unit of work as sign-off:
`iOS/adjust.portrait.svg`, `iOS/adjust.photos.portrait.svg` (already ⚠️ stale
from the interval-warp phase 2 — this rides that redraw), a new
`iOS/adjust.timeslice.portrait.svg` for the expanded state, INDEX rows.

---

## 6a. The processing loader (decided 2026-08-28, Steven)

The Processing screen's blurred hero image is replaced by a **progressive
time-slice build-up** — on *every* blend run, not just sliced ones. The
loading animation is the feature demonstrating itself, largely for free off
the stage-1 machinery.

**Behaviour.**

- The hero is a band composite of the shoot: band j samples the source at its
  full-source ladder position (poster semantics — the whole shoot spread
  across the frame). A sliced run uses the user's segments / axis / newest
  edge; a plain run uses the defaults (24 vertical bands, newest at left).
  The animation's `lag` does not translate to a static composite; the loader
  is always full-source spread by design.
- It starts near-empty and bands **jump in** — hard cuts, no fades, matching
  the slicing aesthetic — one at a time as the run advances: bands revealed =
  ⌊overall progress × S⌋, a band appearing only once its decode has also
  landed. Build order runs across the frame from the configured newest edge
  (default: from the left; horizontal slicing builds from the top/bottom).
- **Layout:** the composite is **100% width at the output's aspect ratio**
  (the canvas-applied shape of the clip being rendered; source aspect as the
  fallback), whatever height that needs, sitting **under the % progress
  ring**. The four-phase checklist card moves **down, directly above Cancel**,
  and the *"Cancelling discards this blended clip. Your original is safe."*
  caption is removed so Cancel sits closer to the bottom.

**Engineering.**

- Band frames decode during the Preparing phase, on `MediaWorkQueue` (already
  bounded), at band-width pixel sizes — a screen-wide composite's band is
  tens of points wide, so these are tiny decodes cached in RAM for the run.
  Interval shoots: `sourceFrameURLs` + `stillsFrameAxis` → indices, decoded
  via `ProjectThumbnailGenerator.imageThumbnail` (the RAW-safe path; iOS DNGs
  cost a real RAW decode per band — bounded by a small `CIRAWFilter.
  scaleFactor` — while macOS decodes fully, which suits Mac-first testing).
  Video shoots: `AVAssetImageGenerator` at small size with **zero tolerance**
  (keyframe tolerance would repeat one GOP across many bands). Bands are
  aspect-filled to the output shape.
- Decodes never contend with the render for priority; a band whose decode is
  late simply appears late. Reduce Motion: reveal still steps (it is already
  discrete), no other motion exists.
- `ProcessingView` is shared across platforms, so the loader is fully
  testable on the Mac. `iOS/processing.portrait.svg` goes stale by definition
  — mirror after sign-off, code-first per the sequencing decision.

---

## 7. Build stages

**Sequencing decided 2026-08-28 (Steven): build first, tested on macOS
first.** Stages 1–3 land and verify entirely on the Mac — the Kit test suite,
the `lapse` CLI, and the macOS app against the real library — before any UI
work starts. **No iOS simulator runtimes are to be downloaded for this job**;
device/iOS verification waits for a later phase. To make the engine drivable
with no UI at all, stage 2 grows a CLI surface:
`lapse slice <blended-clip> -o out.mp4 --segments 24 --lag 2 --axis vert
--newest left [--poster out.png]` — the same `TimeSliceRenderer` the app will
call, runnable on any existing blended clip from the shell (which is also the
parked re-slice path, exercised early).

1. **Kit — pure core.** `TimeSliceSettings`, `TimeSliceGeometry` (band rects,
   remainder distribution, 4:2:0 alignment, validation), `lagLadder`. Unit
   tests (WindowScheduleTests is the template): 720/24 exact, 1920/7
   interleave, sub-2 px rejection, even alignment, ladder shape, direction.
2. **Kit — the pass.** `OrderedFrameProvider`; `AssetFrameProvider`
   (AVAssetReader, native-YUV probe, BGRA fallback); `BandSpool` ring files;
   `TimeSliceRenderer.render(provider:settings:animationURL:posterURL:
   progress:)` with PTS carry, `VideoEncodePolicy` writer settings, poster
   composite, cancellation, and the `lapse slice` subcommand. Tests against
   `VideoSynthesizer` clips: slice a synthetic ramp, assert each band's values
   match its commanded master index (the reference clip's cross-correlation
   measurement, done in-process); poster ladder test; spool round-trip.
3. **App — orchestration.** `startProcessing` tail integration (slice the
   final file just before `storeBlend`); temp master when `includeRegular` is
   off; register one or two BlendProjects; `timeSlice` on the recipe +
   `openBlend` rehydration; the `slicing` progress phase; disk precheck;
   poster metadata via `ImageExporter.carryoverMetadata` from the first source
   frame (the `stackPhotos` precedent).
4. **App — UI.** §6, including readouts, validation, and `ctaTitle` awareness
   ("Create time-slice poster" when Image-only with the regular clip off).
5. **Processing loader.** §6a — the progressive build-up hero on
   `ProcessingView` for every blend run (defaults when no slice is armed, the
   user's settings when one is), plus the layout moves: checklist card above
   Cancel, the cancel caption removed. Buildable and testable on the Mac
   before any slicing UI exists, since it doesn't depend on §6.
6. **Verification.** `tools/timeslice_report.py <clip> --segments N --offset o`
   — per-band luminance cross-correlation against band 0, fitted ladder,
   greppable `TIMESLICE PASS/FAIL` (the `flicker_report.py` culture). First
   E2E runs on the Mac app against the real library (the headless-Mac recipe
   from the interval-adjust work); device/iOS passes come in the later phase,
   no simulators downloaded for this job.
7. **Mirrors + INDEX** after sign-off, per the design-sync contract.

---

## 8. Deferred (unchanged from the brief, plus what §2 makes cheap)

- Re-slice an existing blended clip (§2.2 of the brief): the engine ships it in
  all but UI — a project-detail entry point + provider over a stored blend.
- Feathered edges; eased/exponential ladders (a new array); non-uniform band
  widths, radial/angular maps; the greyscale displacement generalisation.
- Extend-into-unused-source end policy for trimmed video sources.
- watchOS: untouched by design.

## 9. Decisions

**Decided 2026-08-28 (Steven):**
- Build first — engine (stages 1–3) before any UI, verified on macOS only; no
  iOS simulator downloads for this job. Read as: when §6 does start, it goes
  app-code-first with mirrors after sign-off, matching the recent pattern.
- Naming — the attribute scheme in §4 Q7
  (`timeslice-vert-left-segs_24-lag_2`; width auto-calculated, never named;
  no `spread_full` token — the poster simply drops the lag).
- The seven brief questions — see the banner in §4 (offsets in frames; trim;
  full-source poster; master resolution with **no upscaling**; frame-space
  ramps; preview → the §6a processing loader).
- Poster file format: **PNG**.

**Still open:**
1. When *Include regular timelapse* is OFF, should the throwaway master render
   at `hevcMain10` regardless of the user's blend-format default (better
   gradient survival into the slice, zero user-visible cost)?

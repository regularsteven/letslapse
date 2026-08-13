# Ramp segment-switch investigation — 2026-08-11

Follow-up to the warp-ramp truthfulness work: ramp-mode capture loses ~0.6 s
of real time at every segment-file switch (pixel-measured on E197EC62) and the
camera re-meters between formats, leaving a ~3 % one-frame luma step at each
cut (sky 161.8 → 157.5, present in every render — source-inherited). Three
questions were posed; all three are answered below and two ship as code.

## 1. Can the writers overlap, or the switch get faster?

**Overlapping writers: not with `AVCaptureMovieFileOutput`.** One session
supports one movie file output on iOS, and a new `startRecording` may not be
issued until the previous file's `didFinishRecording` arrives (the macOS
seamless-switch behaviour never came to iOS). More fundamentally, most of the
hole is the *sensor reconfiguration*: while `activeFormat` changes, no frames
are delivered at all, so a second writer would have nothing to record. True
gapless switching means `AVCaptureVideoDataOutput` + two `AVAssetWriter`s
rotated on a frame boundary — no format change needed when both rates share a
format — plus pre-rolled writer sessions to kill the ~0.27 s spin-up. That is
a capture-pipeline rewrite (stabilized connections, Apple Log, fragment-
interval crash-safety, the flatten pass all move with it); recorded here as
the endgame, not attempted in this pass.

**What ships instead — the switch avoids the format change entirely.**
`sequenceSharedRampRates`: a ramp run now prefers a single format that
carries BOTH its rates (`captureFormatMatch` sort key, active only while a
ramp sequence runs), and `applyCaptureFormat` skips the `activeFormat`
assignment when the matched format is already active. A base↔burst switch on
a shared format is then a frame-duration change only: no pipeline teardown,
no AE/zoom/colour-space reset, and the hole shrinks to writer finalize +
spin-up. On iPhone the 1080p120 formats advertise 1–120 fps ranges, so
30↔120 shoots share one format; devices where no format carries both rates
fall back to exactly the old behaviour. Side benefit: every segment records
with the same stabilization mode (before, base and burst could land on
formats whose best modes differed — a subtle crop change at the cut).

Rejected micro-optimisation: reconfiguring while the old file finalizes.
Delivery stops the moment the device reconfigures, so frames still in flight
can be dropped from the old file's tail — the hole doesn't shrink, it just
moves into the previous segment.

## 2. Exposure lock across the switch

`beginSwitchExposureHold()` (CameraController): on every ramp toggle, before
`stopRecording`, the sensor's current AE/AWB output is snapshotted
(`exposureDuration`, `iso`, `deviceWhiteBalanceGains`) and immediately
re-asserted as custom exposure + locked white balance — values identical to
what AE was outputting, so nothing visible changes. `applyCaptureFormat`
re-applies the hold after any format/duration change, clamping shutter to the
new frame interval and trading the lost light back in ISO (duration halves →
ISO doubles) so the files match in luma, not just in mode. The hold spans
burst segments whole — both of their cuts must match — and releases one
second into a base-rate segment (from the writer's first-frame callback), so
AE resumes from the held values and any adaptation reads as in-scene drift,
never a step at a cut. The user's manual exposure lock takes precedence
(hold is a no-op; `reassertExposureLock` already carries the lock across
formats). macOS holds via `.locked` modes (no numeric API there).

## 3. Honest gap metadata in sequence.json

Two optional fields on `Segment`:

- `recordedStart` — stamped in the new `didStartRecordingTo` delegate, the
  writer's first-frame callback, on the run's clock. The old `relativeStart`
  is stamped *before* `startRecording` and runs early by the writer spin-up
  (~0.27 s iPhone, ~1.2 s Mac webcam — now measured, see below).
- `recordedDuration` — the finished file's probed media length (header read
  in `finishSegment`, milliseconds against the finalize that just ran).

The measured gap at a boundary is
`next.recordedStart − (prev.recordedStart + prev.recordedDuration)` — the
callback latencies of the two start stamps largely cancel. `warpSourceRegions`
(AppModel) uses the measured gap exactly (no +0.25 s bias) when both
boundary segments carry stamps, and falls back to the old bracket-midpoint
estimate for pre-honest sidecars. Old sidecars decode unchanged (fields are
optional; verified against E197EC62's real sidecar), and old app versions
ignore the new keys.

## Verification so far

**Mac end-to-end (real camera, this machine, 2026-08-11):** seeded base
15 fps / burst 30 fps (the MacBook camera's single 1080p format spans 15–30,
so the shared-format fast path is exercised), drove a Speed-ramp capture via
AX (record → 10 s → burst 4 s → 8 s → stop). Results:

- sequence.json carries honest stamps on all three segments; project
  894519E4-7B8B-4DCC-94CF-7F0E34E99DE0 (left in the library as a fixture).
- Measured gaps 1.103 s and 1.293 s where the old estimator would have said
  0.787 s / 0.863 s — and segment 000's writer spin-up was 1.18 s, directly
  measured (`recordedStart` 1.192 vs wall stamp 0.008).
- Luma across the cuts (ffmpeg signalstats YAVG, 5 boundary frames each
  side): 130.97→131.28 (+0.24 %, within the scene's own ~0.35 luma/s drift
  over the 1.1 s hole) and 132.27→132.32 (+0.04 %). The iPhone baseline
  measurement was a 2.7 % step.
- Adjust opened the capture and seeded the warp normally.
- The real E197EC62 sidecar still decodes; honest/estimate/round-trip math
  covered by a standalone harness (LiveCaptureSequence.swift compiles alone).

**iPhone 16 Pro shoot (2026-08-11, project E579001B, 4K 25 base / 100
burst):** everything engaged.

- Fast path: first segment logged `format switch` (entry from the resting
  format), every ramp switch after it `duration-only (shared format)` — the
  4K format carries 25 and 100 on one format, even at 4K.
- Measured gaps **0.195 s and 0.157 s** where the old pixel-measured figure
  was ~0.6 s — the hole shrank 3–4×. Writer spin-up on the shared format:
  0.030 s / 0.068 s (vs 0.177 s for the cold first segment and ~0.27 s under
  the old full-format switch): the warm pipeline collapses it.
- The old estimator would have said 0.425 s / 0.312 s for this shoot — its
  +0.25 s bias, tuned for 0.6 s holes, now OVERSHOOTS the real gap ~2×. With
  measured stamps the compiler stays truthful on both sides of the fix.
- Exposure hold: `1/221s ISO 67` held; released 1 s into the return
  segment. Burst→base cut photometrically perfect (whole-frame YAVG
  111.81→111.85, +0.04 %; sky strip +0.3 %). Base→burst cut settles at the
  right level (strip continuous with the old tail) but the burst's first
  ~4 frames carried a transient — 2 hot (~+7 %), 2 low — because the
  auto→custom exposure latch takes the ISP a few frames and the old segment
  stopped before it landed, pushing the latch frames into the new file.
- Fix (same day): `beginSwitchExposureHold(completion:)` gates the switch's
  `stopRecording` on `setExposureModeCustom`'s completion (0.6 s timeout
  fallback), so latch frames stay in the old segment's tail at values AE was
  already outputting. The delegate's finish/switch race was also reordered —
  the user's Stop now wins over a pending switch (with both flags set, the
  old order spawned a segment nothing would stop; the latch wait widened
  that window). Latch fix is built and installed but not yet re-shot.

**Remaining (nice-to-have):**

1. ~~One more short iPhone ramp shoot to confirm the burst-head transient is
   gone~~ — **done 2026-08-13**, see below.
2. Kinematics: re-render E197EC62 (or any honest-stamped shoot) and run the
   train-window frame-diff recipe (warp-ramp-truthfulness) — cut outliers
   should drop below the current ~2× envelope now that leadingGap is exact.

## Follow-up 2026-08-13: exposure latched, cadence didn't

Field shoot 043885DE (4K, 25 base / 100 burst, non-flat, non-stabilised).

**The exposure latch fix works — item 1 above is closed.** Whole-frame YAVG:
the pre-burst tail runs 117.87–118.03 and the burst opens 117.99, 118.01,
118.32, 118.43, settling ~118.48. A +0.4 % settle where the pre-fix shoot
showed a 2-hot-2-low ~7 % flicker. The cut is photometrically clean.

**But the same four frames were still at the wrong CADENCE.** QuickTime calls
`segment-001.mov` 98.14 fps. That is the average (820 frames ÷ 8.355 s); the
header declares `r_frame_rate = 100/1` correctly. Per-frame durations at the
600-tick track timescale:

| frames | durations | rate |
|---|---|---|
| 0–3 | 24, 24, **48**, 24 ticks (40, 40, **80**, 40 ms) | 25 fps — the base cadence |
| 4–819 | 6 ticks (three at 5) | 100.061 fps, dead steady |

The 80 ms frame is one dropped outright as the change landed. At 100.061 fps
those 8.355 s should hold 836 frames; 820 arrived, and the 16 missing ones are
exactly the 0.2 s head where 4 frames came instead of 20. No drift, no
sustained drop — the whole shortfall is the switch still landing inside the
new file. The step *down* is clean: `segment-002.mov` is 6214 frames, every
one 24 ticks, zero head transient — slowing the sensor needs no re-timing.

**Why it mattered.** `GuidedPlanner.gatedSpeedChips` offers ¼× only at probed
fps ≥ `4 × outputFPS × 0.98` = 98.0 at 25 fps out, and
`Capture.sourceSegmentFPS` probes this file at 98.1448 — 98.0 × 8.355 s =
818.8 frames against the 820 present, a margin of **1.2 frames**. One more
transitional frame and the burst silently loses ¼×. Separately `VideoBlender`
reads source frames sequentially by count against `WarpCompiler`'s uniform
density assumption, so at an authored ¼× those four 40 ms frames each become
one 40 ms output frame — 0.16 s playing at 1× before snapping to 4× slow.

**Fix (same day).** `prepareRampRateChange(to:)` writes the new frame duration
while the old segment is *still recording*, and the switch's `stopRecording`
is held `min(0.6, max(0.2, 6/oldFPS))` — 0.24 s at a 25 fps base — so the
sensor has re-timed before the next file opens and the transitional frames
stay in the old segment's tail, where a 12-minute base segment absorbs them.
Same shape as the exposure latch above, one layer down.

Gated to the shared-format fast path. This pass's §1 rejected reconfiguring
during finalize because *"delivery stops the moment the device reconfigures"*
— true of a full **format** switch, but a duration-only change on an already
active format does not stop delivery, which is exactly why those four frames
were there to measure. Where no shared format exists, `prepareRampRateChange`
returns false and the old ordering runs verbatim.

`Segment` also gained `measuredFrameRate` / `steadyFrameRate` /
`settleSeconds`, probed in `finishSegment` from a bounded head read of sample
references (48 samples, no decode, 1.5–2 ms even on a 1.7 GB segment).
`settleSeconds` is the regression detector for the constant above — 0.200 on
this shoot, expected ~0 after the fix. Two gotchas worth keeping: the
reference output repeats the first presentation stamp, and it delivers samples
chunk-interleaved rather than in order, so the probe over-collects, sorts, and
keeps a strictly-increasing front half — sorting a tight window instead
stranded a later sample at the end and invented one huge final interval, which
read as "never settles" on every base segment.

### Verified on device — iPad Air M1, 2026-08-13

Project 2B6AD47C, 4K portrait, base 25 / burst 50, run hands-free from the Mac
over the Wi-Fi tunnel with the new `LL_RUN` hook (below), script
`i25x15,b50x5,i25x10`.

**The burst file opens clean.** Head intervals `20, 20, 20, 20, 20, 20 …` —
burst cadence from frame 0. `measured 50.016 == steady 50.016, settle 0.000s`.
Against the pre-fix iPhone burst (`40, 40, 80, 40, 10, 10 …`, measured 98.145
vs steady 100.061, settle 0.200 s) that is the whole defect gone: the average
QuickTime reports now equals the real rate.

**The transient moved exactly where it was designed to go** — segment 000's
tail reads `40, 40, 20, 20, 20, 20, 20, 18.3`. Those 20 ms frames are the
sensor re-timing to 50 while the base segment was still recording. Which also
settles the §1 question empirically: **delivery does not stop during a
duration-only change** — five frames kept arriving and were written.

**Exposure survived the new ordering.** Base→burst cut: tail
116.51–116.65 → head 116.52–116.59 YAVG, flat *through* the transitional
frames, so the mid-recording shutter re-clamp and ISO trade work.
Burst→base: 113.34 → 113.21 (−0.12 %). Hold released 1.02 s into segment 002.

Log line for line: `switch exposure hold: 1/816s ISO 18` → `rampSettle 25→50:
hold 0.24s` → `applyCaptureFormat fps=50 duration-only (shared format)` →
`segment 001 cadence: asked 50 measured 50.016 steady 50.016 settle 0.000s`.

**Three caveats the run exposed:**

1. **The step DOWN is not clean on every device.** Segment 002's head reads
   `20, 20, 20, 40, 40 …` — settle 0.060 s, 3 frames. The hold is skipped on
   step-downs because the iPhone's 100→25 segment was pristine; that
   assumption is device-dependent. Consequence is mild (a base segment's head
   being slightly dense touches no slow-motion gate) but it does leave
   measured 25.177 ≠ steady 25.005 for that segment. Holding on step-downs
   too would push those frames into the burst's tail — harmless there, since
   they are already at burst cadence — at the cost of ~0.12 s of extra burst.
2. **The base segment's average is inflated by its new tail** — segment 000
   measured 25.195 against a 25.005 steady, +0.76 %. That is the cost of the
   design, and it scales away: the same ~6 frames in a 12-minute base segment
   move the average by ~0.01 %. `settleSeconds` will not catch it, since it
   only inspects the head.
3. **The held switch's gap grew.** 0.290 s with the hold versus 0.196 s on the
   unheld step-down of the same run. The prediction was that it would not move
   (the old segment merely ends later). Single run, and a different device from
   the 0.157–0.195 s iPhone baseline — worth re-measuring on the iPhone before
   reading anything into it.

### `LL_RUN` — hands-free runs without the card

`LL_RUN=i25x15,b50x5,i25x10` (DEBUG, `TestCardRigController.armFromLaunchHook`)
arms a scripted run with no card in shot, for a device rigged at a window and
for triggering from the Mac over the Wi-Fi tunnel — touching a mounted iPad to
start a take shakes the frame the take is measuring. It routes through the same
`lock` → countdown → `beginRun` path a card sighting takes, so only the ARMING
differs and the two are directly comparable. Gated on the screen being idle in
Video mode.

```bash
xcrun devicectl device process launch --device <udid> --console \
  --terminate-existing \
  --environment-variables '{"LL_CAPTURE":"1","LL_RUN":"i25x15,b50x5,i25x10"}' \
  com.regularsteven.letslapse
```

Wi-Fi is enough — the iPad reports `transportType: localNetwork`; install,
launch, console and file pull all work untethered. Note Apple Watch cannot
drive an iPad: `WCSession.isSupported()` is false on iPadOS, so
`WatchRemoteControlReceiver` no-ops there.

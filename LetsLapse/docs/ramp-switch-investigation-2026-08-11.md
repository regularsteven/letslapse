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

1. One more short iPhone ramp shoot to confirm the burst-head transient is
   gone (sky-strip YAVG on the burst's first ~10 frames should be flat).
2. Kinematics: re-render E197EC62 (or any honest-stamped shoot) and run the
   train-window frame-diff recipe (warp-ramp-truthfulness) — cut outliers
   should drop below the current ~2× envelope now that leadingGap is exact.

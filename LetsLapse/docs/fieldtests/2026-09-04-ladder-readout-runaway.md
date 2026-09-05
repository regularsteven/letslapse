# Ladder run on the 12 Pro: the readout ran away while the frames stayed right (2026-09-04)

**Brief (Steven, 2026-09-05):** an evening Ladder shoot on the iPhone 12 Pro
(Create ▸ Interval ▸ Ladder ▸ "Bright & Fast, Dark & Slow"). The screen had
been dimmed for a while; when Dim was turned off, with the light fading, the
run readout said something like **1/7000** and a red exposure warning. The
shoot was stopped on that. On review the frames are correctly exposed and
their EXIF shutter speeds are sane — the readout was wrong, not the shoot.

**Project:** `/Volumes/letslapse/Projects/8BC64DBE-C5D2-4169-8F5F-21D28DF41B9D`
(500 JPEG outputs, 17:29:21Z → 17:50:06Z, `endReason: user`).
**Device:** iPhone 12 Pro (iPhone13,3), iOS 26.6.1 (23G83), "Back Triple
Camera" (virtual), JPEG live-blend pipeline. **Device logs pulled 2026-09-05**
(`Logs/ladder-2026-09-04T17-29-21Z.jsonl`, `liveblend-20260904-192921.json`,
plus the two neighbouring runs).

## Verdict

Two faults stacked, and a third rode on them:

1. **The ramp never drove the camera.** `capture_log.json` carries one issue at
   window 0: `ramp commanded nothing — exposure is AE-driven` (kind `ramp`,
   severity `problem`). Every `applyHolyGrailExposure()` for 21 minutes was
   refused, so the sensor ran on plain auto-exposure. That is *why the frames
   are fine.* The refusal reason (`customExposureUnsupported` / `lockFailed` /
   …) went to the Xcode console only, which nobody was attached to.
2. **The ramp's model then ran away on its own.** On the JPEG path the scene
   measurement is `EV(commanded pair) + log2(luma / 0.18)`. That is
   scene-referred only while the camera obeys the command. With the camera on
   AE the luma never answers a step, so every step the engine takes is read
   back as the scene having moved the same way — a unity positive-feedback
   loop. The engine's target walked from 1/305 to **1/71429 s** (the format's
   14 µs floor) and its "scene EV" from 11.6 to **19.6**, while the delivered
   frames went 1/296 → 1/121 s and EV 11.2 → 8.8 (dusk, as expected).
3. **Everything downstream believed the engine.** The amber run line prints
   `engine.currentTarget` (so 1/7752 at 17:43, 1/71429 by 17:47), the red
   "past the sensor's limit" is `engine.isClipped` (true once the wanted gain
   fell under the floor, from ~17:47), and the **Ladder stepped UP to
   "Daylight" at 17:37:53** on the phantom EV 13.5 — the clip's pacing
   changed from every 2 s × 5 frames to every 3 s × 10 mid-dusk. That last one
   is in the finished clip, not just on the screen.

**Dim is exonerated.** `ShootScreenDimmer` floors `UIScreen.brightness` and
puts a black cover over the viewfinder; it touches nothing in the capture
session. The cover hid a readout that had been wrong since 17:32:38 — the
first phantom step — so the number was simply first *seen* when the cover
came off.

## Evidence

### Commanded vs delivered, same run

`frames.timestamps` on a ramped run records the engine's **commanded** pair
per window (the `shutter`/`iso` handed to `advanceHolyGrailRamp` are
`engine.currentTarget`); `capture_log.json` records the pair the device was
actually at when each window opened. Side by side:

| window | time (Z) | commanded shutter | engine EV | delivered shutter | delivered ISO | delivered EV |
|---:|---|---:|---:|---:|---:|---:|
| 1 | 17:29:24 | 1/305 | 11.60 | 1/296 | 33 | 11.16 |
| 98 | 17:32:38 | 1/333 ← first step | 11.75 | 1/269 | 33 | 11.03 |
| 200 | 17:36:02 | 1/626 | 12.68 | 1/207 | 33 | 10.65 |
| 254 | 17:37:50 | 1/1133 → Ladder steps to Daylight | 13.52 | 1/174 | 33 | 10.40 |
| 300 | 17:40:08 | 1/2160 | 14.49 | 1/128 | 33 | 9.96 |
| 361 | 17:43:11 | 1/7752 | 16.31 | 1/121 | 44 | 9.46 |
| 443 | 17:47:17 | 1/71429 (floor) | 19.53 | 1/121 | 55 | 9.15 |
| 500 | 17:50:06 | 1/71429 | 19.64 | 1/121 | 71 | 8.78 |

Delivered ISO/shutter agree with the JPEGs' own EXIF (`mdls` on the frames),
so the file metadata is the truth and the readout was the lie.

### The measurement, separated into its two terms

The sidecar's `ev` is the engine's EMA (α = 0.15), so the raw measurement can
be recovered exactly: `m(t) = s(t−1) + (s(t) − s(t−1)) / α`. Subtracting the
commanded-pair EV leaves the luma term `L = log2(luma / 0.18)`:

| windows | commanded-pair EV | luma term L | mean linear luma |
|---|---:|---:|---:|
| 1–20 | 11.21 | 0.40 | 0.24 |
| 100 | 11.33 | 0.53 | 0.26 |
| 250 | 12.96 | 0.56 | 0.27 |
| 400 | 17.11 | 0.76 | 0.30 |
| 480–500 | 19.08 | 0.58 | 0.26 |

Over the whole run L stayed inside 0.37–0.78 — the AE-rendered frames' mean
luma moved 0.17 stops — while the commanded-pair term climbed 7.9 stops. Had
the measurement used the *delivered* pair, it would have read 11.55 → 9.32:
a 2.2-stop darkening, matching the frames. The runaway is entirely the
commanded term feeding itself.

### Why it stairsteps at exactly the deadband

Every phantom step is 0.12–0.14 stops (1/305 → 1/333 → 1/364 → 1/396 …): the
engine's `deadbandStops = 0.12`. After a step of `s`, the commanded term jumps
by `s`, the EMA climbs toward it over ~1/α windows, the error re-crosses the
deadband, and the engine steps again in the same (already committed)
direction — no dwell applies. Observed cadence: 16–20 windows at first,
accelerating to 5–6 as the real AE drift (L rising 0.4 → 0.75 while the sun
dropped) added to it. The trigger was that 0.14-stop luma rise in the first
eight minutes; once over the deadband the staircase is self-sustaining.

### Three Ladder runs that evening, same device, same pipeline

| run (Z) | windows | engine EV start → end | rung changes | note |
|---|---:|---|---|---|
| 17:12:46 | 100 | 8.45 → 14.05 | Fading → Daylight at w89 | same runaway, 3.5 min |
| 17:29:21 | 501 | 8.01 → 19.64 | Fading → Daylight at w254 | this report |
| 17:51:53 | 224 | 7.99 → 8.11 (peak 9.07) | Dusk → Fading at w1 | ramp refused again; held 1/45 for 160 windows, then walked the *other* way (1/45 → 1/26) once dusk pushed the luma term down — see below |

None of the four `liveblend-20260904-*.json` experiment logs carries an
`exposureDivergenceStops` stamp, which is *ambiguous by construction*: the
stamp needs a commanded target, and a nil target skips it. Only
`capture_log.json`'s one-shot issue distinguishes "in agreement" from
"nothing commanded". (The 18:00:41Z run, 1056 outputs, has no ladder log and
was not a Ladder run.)

## The second shoot (17:51:53Z, project `0F387359-FD7D-45E4-9A51-959ACED13D29`)

Reviewed 2026-09-05 at Steven's request. 223 outputs, every 2 s, Ladder
built-in, JPEG. It confirms every observation above and adds one:

- **The ramp was refused again** — same `ramp commanded nothing` issue at
  window 0. Three Ladder runs, three refusals; the refusal is not
  intermittent on this phone.
- **The seed re-split makes the readout disagree with the EXIF even when
  nothing is wrong.** AE was delivering 1/121 s ISO 90; the ramp re-split
  that gain shutter-first to 1/45 s ISO 33 and printed it. Same exposure,
  different numbers — an operator checking the amber line against a frame's
  EXIF sees a mismatch from the first second.
- **The walk happened, in the opposite direction.** The luma term sat at
  0.59–0.62 for 160 windows (inside the deadband, target held at 1/45), then
  dusk pushed it down to 0.37 and the staircase started the other way:
  1/41 at w161, 1/38, 1/35, 1/32, 1/29, 1/26 at w217 — 0.13-stop steps every
  ~10 windows, the same signature as the first run with the sign flipped.
  Had the run continued it would have walked to the 1 s ceiling. Direction is
  set by the sign of the luma drift; the mechanism is identical.
- **No Daylight step in this run.** The only rung change is *Dusk → Fading at
  window 1*, three seconds in — the toast read "Stepped up to Fading". It
  happened because the arming EV (7.99, sign-flipped helper, ~0.3 low at
  ISO 90) chose Dusk, and the engine's first luma-path measurement (9.04,
  0.6 above the frames' EV 8.42 because the frames' mean luma sits above
  mid-grey) crossed the selector's 8.5 band at once. Two EV scales, one
  absolute consumer. A "Stepped up to Daylight" toast that evening belongs to
  the first run (17:37:53Z); its rail would also have shown Daylight whenever
  the dimmed screen was woken after that.

| | window 1 | window 223 |
|---|---|---|
| readout (engine target) | 1/45 s ISO 33 · EV 9.0 | 1/26 s ISO 33 · EV 8.1 |
| delivered (EXIF) | 1/121 s ISO 90 · EV 8.4 | 1/50 s ISO 111 · EV 6.8 |
| real change | | −1.6 stops (readout moved −0.8) |

## Side finding: the Ladder's arming EV has its ISO sign flipped

`CameraController.sceneExposureValue()` returns
`log2(N²/t) + log2(ISO/100)`; EV at ISO 100 is `log2(N²/t) − log2(ISO/100)`
(as `DNGAuthor.DNGExposure.exposureValue` and `HolyGrailRampEngine.sceneEV100`
both compute it). At ISO 33 that is 3.2 stops low — the 17:29 run armed on
"scene EV 8.0" for a scene the frames say was 11.2; the 17:51 run opened on
**Dusk** and stepped to Fading one window later. At ISO 3200 it would read
**10 stops high**, i.e. a night scene arms on Daylight. Callers:
`armLadder` (fallback), `meterLadderPreview` (the idle light panel), and the
Scanner torch decision (`scannerTorchEVThreshold = 5`, tuned against the
wrong scale — re-tune it when the sign is fixed).

## What the logs could and could not tell us

Enough, barely, and only by combining four sources: the project's
`capture_log.json` (delivered pairs + the one issue), `frames.timestamps`
(commanded pairs + engine EMA — undocumented as such; the schema says
"exposure time in seconds"), the ladder `.jsonl` pulled off the device (rung
changes + engine EV), and reading the code to know which number the readout
prints. The refusal reason, the constituent that was active, and whether the
ramp ever recovered are all console-only and gone. Specific gaps:

1. **The refusal reason is not in the project.** `HolyGrailApplyOutcome` is
   named, then only `LLog`ged. The issue says "commanded nothing" without why.
2. **One-shot issue, no recovery marker.** "commanded nothing" is emitted once
   at window 0; a ramp that starts driving at window 40 leaves no trace.
3. **`frames.timestamps` silently changes meaning.** Basic run: delivered
   pair. Ramped run: commanded pair + engine EMA. Nothing in the file says
   which, and `ev` is the *anchored* (relative) luma EV printed as if
   absolute — the same number the HUD shows as "EV 19.6".
4. **The divergence guard is silent exactly when it matters.** With a nil
   target it compares nothing; the engine's `currentTarget` is always
   available and is the number the operator is looking at.
5. **The experiment log loses its name.** `CaptureView.onFinishLiveBlend`
   appends `result.logURL` to the frame list, so registration renames it
   `frame-00501.json` — the trap the comment in `registerImport` warns about
   for sidecars. On the phone `F213A5A3…/source/frame-00196.json` is the same.
6. **Console lines do not persist.** `LLog` is `print`; the crash-safe
   `CaptureSessionLogger` NDJSON is deleted on a normal finish. A run that
   ends normally keeps no narrative at all.
7. **No per-window record of what the ramp thought.** Commanded pair,
   smoothed EV, aim, luma, AE gap, apply outcome — none of it is in
   `capture_log.json`, which is the one document that travels with the
   project.

## Proposed logging (the schema changes)

All additive, all optional fields, all in `capture_log.json` so they travel:

- `Entry.ramp` (ramped runs only): `commandedShutter`, `commandedISO`,
  `smoothedEV`, `aimEV`, `measuredLuma` (JPEG) / `apexBrightness` (DNG),
  `aeGapEV`, `applied: Bool`, `applyOutcome: String?` (nil when applied).
- `exposureDivergenceStops` computed against `engine.currentTarget` when the
  applied target is nil, flagged `divergenceReference: "engine"` vs
  `"applied"`.
- Issues: `ramp` `problem` with the outcome reason and device facts
  (`isVirtualDevice`, active constituent, `exposureMode`,
  `isExposureModeSupported(.custom)`) at seed, at retry and on the first
  per-window refusal; a `ramp` `info` "driving again at window N" on
  recovery; a `ladder` `info` per rung change with the EV that caused it.
- `Session.rampDriving: Bool` and `Session.rampRefusals: Int` in the header
  so `shoot_audit.py` can grep one field.
- `frames.timestamps`: a header line (`{"kind":"ramp"}` / `{"kind":"delivered"}`)
  or, simpler, always write the delivered pair and move the commanded pair
  into `capture_log.json` where it belongs.
- Keep the experiment log's name on registration (`liveblend-<stamp>.json`,
  outside `sourceFileNames`, like the other sidecars).
- Persist the run's `LLog` lines to `Logs/console-<run>.log` (ring-buffered
  per run), or stop deleting the `CaptureSessionLogger` NDJSON for ramped runs.

## Proposed fixes (ranked; none applied yet)

1. **Measure through the delivered exposure, never the commanded one.** In
   `advanceHolyGrailRamp` the luma path must take the pair the frames were
   actually shot at (the window's `record.exposure`, or better each sample
   buffer's own EXIF attachment, which also carries `BrightnessValue` — then
   the JPEG path can use `.apexBrightness` exactly like the DNG path). With
   the delivered pair the measurement is scene-referred by construction, the
   ISP-quantization leak the 2026-08-25 deadband was added for disappears
   from the measurement, and a non-driving ramp tracks the real scene instead
   of itself. Regression test to add beside `testAConstantSceneNeverMovesTheRamp`:
   an open-loop camera (luma constant regardless of command) must leave the
   target within the deadband after 500 windows.
2. **The run readout must not print a target the camera is not on.** When
   `holyGrailAppliedExposure` is nil the amber line should show the delivered
   pair (`liveExposure`) with "ramp not driving · on AE", and "past the
   sensor's limit" must require a driving ramp (or compare delivered, not
   wanted). This is the TODO's open product call (c) from the actuation job,
   now with a false alarm that cost a shoot.
3. **The Ladder selector must resolve on a scene-referred EV** — the AE
   opinion (`aeSceneEV`, from the delivered pair + `exposureTargetOffset`) or
   the buffer brightness — not `engine.smoothedEV`, which is anchored and only
   relatively correct. And fix `sceneExposureValue()`'s sign (re-tune the
   torch threshold with it).
4. **Find out why the 12 Pro refuses `.custom` on the virtual camera.** The
   2026-08-27 "arm after the constituent lock" change is in this build (the
   ladder exists) and did not help here. The refusal is what the repro below
   answers in one run.

## Reproduce it (Steven)

The false readout needs only a run whose ramp is not driving; the walk itself
needs ~10 minutes of slowly changing light (or one deliberate nudge).

1. Same phone, same mode: Interval ▸ Ladder ▸ "Bright & Fast, Dark & Slow",
   JPEG output (DNG off), Dim off so the line stays visible. Auto-Lock →
   Never.
2. Launch from the Mac **with the console attached** — this is the whole
   point, it captures the refusal reason:

   ```bash
   xcrun devicectl device process launch --device 5E55775F-D1B8-5E23-8D7C-C9607E3D3948 --console --terminate-existing com.regularsteven.letslapse
   ```

   No `LL_*` env vars. Start the run by hand on the phone, or over the
   remote (`setLadder:builtin` then `startRecording`).
3. Grep the console for, in order:
   `optics: constituent switching locked to …` (which physical lens),
   `holygrail: re-split the AE seed …`,
   `holygrail: the seed exposure did not reach the camera (…)` and
   `holygrail: WARNING — the ramp is NOT driving this camera (…)` — the
   bracketed text is the answer we do not have —
   `liveblend: RAMP NOT DRIVING …`, and any `ladder: stepped up …`.
4. Provoke the walk without waiting for dusk: point at a steady scene and,
   after ~30 windows, shade a quarter of the frame (or run the monitor test
   card's `?light=` ramp). The amber line should start stepping in 0.12-stop
   increments every ~15 windows and not stop. Note the time it first
   disagrees with the frames' EXIF by more than half a stop.
5. Controls, one run each, same scene: (a) Dynamic instead of Ladder — same
   pipeline, tells whether the refusal is mode-specific; (b) DNG output on —
   arms on a physical constituent, the path the 2026-08-23 run ramped on;
   (c) Ladder with blend 1 — the isolation trick from the iPad bracket bug.
6. Afterwards pull `Logs/` (the command in `CLAUDE.md`) and the project's
   `capture_log.json` + `frames.timestamps`; the reconstruction below shows
   the two terms.

What to write down while it runs: the amber line's text and the clock when
it first looks wrong, whether the rung toast fires, and whether the frames
in the grid look right at that moment — that last one is the tell that the
readout, not the camera, is off.

## Reconstruction method

```python
import json, math
rows = [json.loads(l) for l in open('frames.timestamps')]
N2 = 1.6 * 1.6            # wide lens f-number squared
alpha = 0.15              # HolyGrailRampEngine.defaultSmoothing
prev = None
for r in rows:
    cmd_ev = math.log2(N2 / (r['shutter'] * r['iso'] / 100))
    raw = r['ev'] if prev is None else prev + (r['ev'] - prev) / alpha
    luma_term = raw - cmd_ev          # log2(luma / 0.18)
    prev = r['ev']
```

Pair each line with the same `frameIndex` in `capture_log.json` for the
delivered pair; if `luma_term` is flat while `cmd_ev` climbs, the ramp is
chasing itself.

## What shipped (2026-09-05, `ios-app`, uncommitted)

Everything in the ranked list above, in one pass:

1. **The measurement reads through the delivered pair.** The video-tap
   controller now reads each selected frame's own EXIF off the sample
   buffer (`LiveBlendController.frameExposure(of:)` — iOS buffers carry
   `{Exif}`: ExposureTime, ISO, FNumber, BrightnessValue) and hands the ramp
   a `BlendWindowScene` — luma, mean brightness, the frames' pair, count.
   `advanceHolyGrailRamp` derives the luma EV with
   `HolyGrailMetering.sceneEV100(meanLinearLuma:deliveredShutterSeconds:…)`,
   never the engine's target; with no frame EXIF the device's current pair
   stands in (still the closed window's exposure). The JPEGs' baked EXIF
   and `capture_log.json` now carry the frames' real pair too. Five Kit
   tests pin it, including the runaway itself
   (`testMeteringThroughTheCommandedPairIsTheRunaway`).
2. **The readout is honest.** `HolyGrailState` carries `isDriving`, the
   delivered pair and the refusal reason; when the last write was refused
   the amber line prints `1/121 · ISO 71 · EV 8.8 · ramp not driving`, never
   the target and never red; the reason sits behind the Info toggle
   (`rampRefusedNote`). Mirror:
   `docs/design/iOS/capture-interval.holygrail-running.refused.portrait.svg`,
   staged by `LL_HOLYGRAIL=refused`.
3. **The Ladder resolves on the AE's scene EV** (delivered pair +
   `exposureTargetOffset`), the scale its rungs are authored on; the
   readout's EV is the same number. `sceneExposureValue()`'s ISO sign is
   fixed; the torch threshold's scale note says why it did not move.
4. **Logging that travels.** `capture_log.json` entries carry `ramp`
   (commanded pair, smoothed/aim/scene EV, luma or brightness, AE gap,
   `applied`, `applyOutcome`, rung); `window.divergenceReference` says
   whether a divergence was measured against the applied or the engine
   target (the engine now stands in when nothing was applied); the header
   carries `rampDriving` / `rampRefusals`; `issues[]` records refusals with
   the reason and device facts (virtual/physical, constituent, switching
   lock, `.custom` support, exposure mode) on transitions only, recoveries,
   and every rung change with its EV — on both pipelines (the DNG path had
   no issue trail). `frames.timestamps` records the delivered pair on ramped
   runs, as its schema always said. The experiment log keeps its
   `liveblend-…json` name in the project. Every `LLog` line is also
   appended to `Logs/console-<launch>.log` (8 MB cap, last 12 launches).
5. **`tools/ramp_audit.py <project>`** prints the verdict, the ramp/ladder
   issue trail and the commanded-vs-delivered table — from the new records,
   or reconstructed from `frames.timestamps` for older logs (it reproduces
   the table above from the 8BC64DBE project). Exit 1 when a ramp never
   drove.

Still owed: the console-attached run on the 12 Pro that names the refusal
(the new `issues[]` line will carry it even without a console), the
simulator check of the amber line's fit, and Steven's sign-off of the mirror.

## See also

- `docs/holygrail-ramp-actuation.md` — the 2026-08-26 discovery of the same
  refusal on the 16 Pro, and the still-owed bench verification.
- `docs/light-ladder.md` — the rung selector reads `smoothedEV`.
- `docs/TODO.md` ▸ "Ramp readout runaway on a non-driving ramp".

# The ramp that wasn't driving — Holy Grail exposure actuation

**Raised:** 2026-08-27 · **Code landed 2026-08-27 · bench verification owed**

## What this is about

On 2026-08-26 the "purple frame 0" was traced to `seedHolyGrailRamp` seeding the
ramp from the **live preview's** AE split — a shutter capped at one preview
frame (~1/17 s) with the whole exposure bought in ISO. In the dark that is the
same light gain at ten times the noise, and the clipped black floor lifts blue
hardest (blue carries the largest white-balance gain), so frame 0 of a night
shoot renders violet while every frame after it is clean. The fix — re-split the
same gain through the run's own shutter-first policy,
`HolyGrailRampEngine.split(gain:limits:)` — shipped in `efd3bb8`.

Re-reading that session's bench consoles afterwards showed the fix was landing
in a hole. **On the JPEG live-blend pipeline the ramp was not actuating at all.**
The seed was computed, published to the capture chip, and thrown away.

## The evidence

Three consecutive Dynamic runs, iPhone 16 Pro, 2026-08-26:

1. `holygrail: WARNING — this camera does not support custom exposure; the ramp
   cannot drive it` on **every** run. `applyHolyGrailExposure()` guarded on the
   *same* predicate and returned silently, so the seed never reached the sensor.
2. `holyGrailAppliedExposure` therefore stayed nil → `rampExposureForBracket()`
   returned nil → the commanded-vs-delivered honesty guard in both blend
   controllers skipped its entire body. `EXPOSURE DIVERGENCE` appears **zero**
   times across all three logs.
3. At stop the engine reported `HG[1.0000s ISO 104]` while the frames landed at
   `0.384 s ISO 5184` — about **4.3 stops apart**, with no complaint anywhere.

The run looked healthy in every artifact it produced. That is the real finding:
the failure was not just present, it was *invisible*, and it was invisible
because the one instrument that would have caught it needs a commanded value to
compare against and there wasn't one.

## Why the two pipelines differed

The pipelines armed the ramp at different points in the camera's life:

- **DNG** (`startLiveBlendDNG`) swaps the session input to a **physical**
  constituent, *then* arms. A physical device takes a custom exposure. This is
  why the 2026-08-23 Prague run ramped correctly — and why the purple frame 0
  was a seed bug rather than an actuation one.
- **JPEG** (`startLiveBlend`) armed while `videoDevice` was still the **virtual**
  back camera with constituent auto-switching live;
  `lockConstituentSwitchingForRun()` ran about 1.3 s later.

The working hypothesis is that a virtual device with switching unlocked refuses
`.custom`. It is *not confirmed* — and deliberately, the fix does not depend on
it being right. Arming after the pin addresses the hypothesis; the other two
changes make any remaining refusal loud instead of silent.

## What changed (2026-08-27, `ios-app`)

`App/CameraController.swift`

- **The JPEG path arms after the pin.** `beginHolyGrailForBlendRun` moved from
  beside its `onWindowOpened` wiring to immediately after
  `lockConstituentSwitchingForRun()`, before the sample-buffer delegate is set.
  Nothing in the stretch between the two positions reads ramp state and there
  are no early returns in it.
- **`applyHolyGrailExposure()` returns a `HolyGrailApplyOutcome`** — applied /
  no device / no target / custom-exposure unsupported / lock failed — instead of
  three unlogged early returns. The arm logs the reason when the write is
  refused. The separate `isExposureModeSupported(.custom)` warning is gone: it
  duplicated the predicate of the write that was failing beside it, which is how
  a true warning sat next to a silent failure and read as advice.
- **One bounded retry**, folded into the settle hold that already existed
  (`afterHolyGrailSeedSettles`): a refused write raises the hold to
  `holyGrailSettleSeconds` and re-attempts when it elapses. The log now says
  "seed applied", "seed exposure applied on retry", or
  `WARNING — the ramp is NOT driving this camera (<reason>)`. Both the hold and
  the retry flag are cleared in `endHolyGrailIfActive` before its
  `holyGrailActive` gate, so neither can be inherited by the next run.

`App/LiveBlendController.swift`, `App/LiveBlendRawController.swift`

- **The honesty guard now fires on silence.** On a ramped run
  (`configuration.rampExposure != nil`) a nil target *is* the fault. Both
  controllers report it once per session; the JPEG one also appends
  `kind: "ramp", severity: "problem"` to the `issues[]` trail, which puts it in
  `capture_log.json` where `tools/shoot_audit.py` can see it.
- The RAW bracket-build path (`fireBracket`) has the same nil-target fallback to
  AE brackets, but runs on the same windows as the guard above, so it is covered
  by that one report rather than duplicating it.

No UI changed, so no SVG mirror applies: no SwiftUI layout, copy, colour or
control moved. `publishHolyGrailState` fires ~1.3 s later on the JPEG path; the
chip itself is untouched.

## Bench verification — owed

Both pipelines, because they arm differently. Per the workflow in `CLAUDE.md`:

1. Build signed Debug to an isolated DerivedData, `devicectl device install app`.
2. `xcrun devicectl device process launch --device <udid> --console
   --terminate-existing com.regularsteven.letslapse` — no `LL_*` env vars, or
   the camera never opens itself and the listener never starts. Harvest `code=`.
3. `./remote_probe <code> "setIntervalMode:holyGrail,setFramesPerBlend:1,
   startRecording,poll@10x6,stopRecording,poll@5x4"`.
4. Repeat with DNG output enabled in Settings so the run takes
   `startLiveBlendDNG`.

Pass conditions, per run:

- **no** `RAMP NOT DRIVING` line, and no seed-refusal WARNING;
- a `re-split the AE seed` line whose numbers match the first frame;
- `capture_log.json` frame 0's `iso` / `exposureDuration` within a quarter stop
  of frames 1–3 — this is the actual frame-0 regression test, and the one that
  would have caught the original purple frame;
- `EXPOSURE DIVERGENCE` either absent *or* present. It must no longer be
  ambiguous: silence used to mean both "in agreement" and "nothing commanded".

A dark scene is not required — the seed re-split fires in any light (the bench
saw 4.6 stops off the shutter in an ordinary dim room). A genuine dark→light run
is still wanted, but as ramp-quality work, not as the actuation check.

## Open question, deliberately not answered here

Should a Dynamic run whose ramp cannot actuate refuse to start, or fall back to
Interval with the dial reset? Today it runs and says so in the log and in
`issues[]`. Making it visible to the person holding the phone is a UI surface
and a product call — and it needs the design-sync pass that this job did not.

## See also

- `jpeg-holygrail-wb-brief.md` — the other half of the JPEG Holy Grail story
  (white balance baked into 8-bit output).
- `holy-grail-algorithm-brief.md` — the ramp policy itself.

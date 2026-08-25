# 2026-08-25 — Scheduled dawn runs: the frozen anchor, the servo limit cycle, and the zombie stall

Two devices, same build, same configuration: scheduled start 05:30 local
(03:30Z), Interval · Dynamic (holy grail) · JPEG · BLEND unthrottled · 3 s ·
Capture Flat. Both on tripods, untouched until ~07:47–07:49.

| | iPad Air M1 (1a) | iPad Air M1 (1b, control) | iPhone 12 Pro |
|---|---|---|---|
| Project | `385DC396` | `BC0F72E6` | `FC69DAEB` |
| Frames | 2753 | 5 | 635 |
| End | 07:47 user stop | 07:49 user stop | 07:50 `consecutiveProcessingFailures` |
| Verdict | ran to plan, output **6.1 stops dark** + oscillation | correct exposure | died at 06:01, pronounced dead at 07:50 |

All three source sets audited with the new
`tools/source_flicker_report.py` (see §Tooling).

---

## 1 · Why 1a came out dark while 1b was correct (Observation 1)

Root cause was diagnosed in this morning's earlier session and is confirmed
against the full data: **the JPEG path's whole-frame mean-luma servo defends
the seed frame's brightness for the whole run** (`anchorsToSeedExposure`),
and the meter it steers by is only ~57 % exposure-invariant.

- The servo held delivered mean linear luma pinned at 0.0257 (≈48/255) — the
  **pre-dawn** rendering — for 2 h 17 m of sunrise. `measuredEV − appliedEV`
  sat at −2.810 ± 0.013 stops all run: the loop was in perfect equilibrium,
  defending the wrong setpoint.
- Applied exposure meanwhile walked 15.7 stops (1/14 s · ISO 822 → 77 µs ·
  ISO 18) — the ramp mechanics are healthy; the *target* is wrong.
- Two errors compound: device AE renders pre-dawn ~3.48 stops darker
  (relative to mid-grey) than it renders daylight, and the anchor forbids
  that rendering change; the whole-frame mean's crush/clip leaves a residual
  loop gain of 0.43, multiplying the setpoint error by 1/(1−0.43) ≈ 1.75.
  Predicted 6.10 stops under; measured against the control: **1a ended at
  77 µs where 1b's fresh AE anchor chose 5364 µs at the same ISO on the same
  scene two minutes later = 6.12 stops.**
- A short run always looks fine (1b did): it re-anchors on correct AE and
  has no time to walk. Reproducing this class needs hours.

**Fix direction (the "idiot mode" contract):** Dynamic mode's promise is
that the shoot *ends* where AE would meter the ending scene. The anchor
should therefore not be frozen; it should **drift, slowly and rate-limited,
toward consistency with the device's own live AE opinion**
(`exposureTargetOffset` is continuously available on the video tap, custom
exposure or not). A drift capped at ~1/20 stop per window is invisible
frame-to-frame but re-renders a 2-hour dawn the way AE would — 1b's look.
Second, make the meter closer to exposure-invariant (clip-aware trimmed
mean / percentile mix instead of the raw whole-frame mean) so residual loop
gain stops amplifying whatever error remains. Guard rails: the drift term
must stay far below unity loop gain (the 2026-08-15 runaway is the standing
lesson), and `testAConstantSceneNeverMovesTheRamp` plus a new
drift-converges-to-AE test gate it in the Kit.

## 2 · The flicker is a ramp-servo limit cycle (Observation 2)

`source_flicker_report.py` on 1a: **13 oscillation events, 99 frames
(3.6 %), plus 81 single visible steps** — and every event carries the same
signature: *the applied exposure toggles between exactly two ISP-latched
states, window after window*:

```
OSCILLATION frames 2389–2402 (13 flips)   ← Steven's eyeballed group
  amplitude median 0.087 stops
  applied exposure TOGGLES between two latched states 0.219 stops apart
  (gains 0.00209 / 0.00243)                ← 135 µs vs 116 µs at ISO 18
```

Mechanism, fully evidenced in the log:

1. At the bright end the iPad is pinned at ISO floor 18 with a sub-200 µs
   shutter, where the ISP only **latches coarse discrete shutter states**
   (the 2026-08-22 bench finding: durations ≲1/253 s never latch exactly;
   the log's `iso`/`exposureDuration` are device read-back, and they hold
   two values). Adjacent latch states run 0.18 → 0.22 → 0.31 → **0.37
   stops** apart as the shutter shortens — which is why the flicker worsens
   toward the end of the run.
2. The ramp engine has **no deadband and no hysteresis**: every window it
   commits a move toward the wanted gain, up to 1/3 stop. The correct
   exposure sits *between* two latch states, so the device alternates: too
   bright → command down → snaps to the dark state → too dark → command up →
   snaps back. A textbook limit cycle around a quantizer.
3. The loop also carries a **one-window delay** (a window's mean luma feeds
   the ramp at the *next* window's open), which is what makes the flip-flop
   period exactly one window.
4. Delivered amplitude (0.08–0.16 stops) is not the commanded toggle: the
   711–723 event flickers 0.12 stops on a 0.04-stop commanded toggle — the
   ISP's tone response amplifies small exposure flips. The pixels are the
   ground truth; that is why the audit measures them.

The iPhone 12 Pro ran the same dawn with **zero oscillation events** (mean
|Δ| 0.0065 stops): its segment lived at 1/42 s-class shutters where latch
quantization is fine. The blend-count jitter visible in the events (84↔85)
is boundary noise, not the cause — the 2026-08-22 blend-count flicker class
stays fixed.

**Fix direction (Question 3 — the confidence idea is right):** in
`HolyGrailRampEngine.advance`, commit a move only when it clears a
**deadband** (error above ~1/6 stop) *and* has **persisted K consecutive
windows in the same direction** (dwell, K≈3); add **hysteresis** so a move
is not reversed until the error crosses the band the other way by more than
the actuation quantization; keep an emergency bypass (error > ~1 stop steps
immediately, so a light switch still ramps promptly). Cost: ~K windows of
extra lag (≈9 s at 3 s interval) — nothing against a dawn that moves a stop
in minutes. Pure Kit change, unit-testable: a synthetic quantized actuator
under slow ramp must produce monotone steps and zero steady-state toggles.

## 3 · The iPhone's death, minute by minute (Observation 4)

The `issues[]` trail and window records give the whole story:

| Local | Event |
|---|---|
| 05:30 | Start, nominal. Unthrottled at 3 s = **68-frame blends per window** (~23 fps effective stacking — video-rate compute, forever). |
| 05:36 | thermal fair (win 135) |
| 05:40 | thermal serious (win 200) |
| 05:46:01 | `framingGlitch`: rejected 63/69 frames, peak shift 44 px (win 319) |
| 05:46:04 | thermal **critical**; glitch 75/75 @45 px; **"framing moved and stayed — new baseline adopted"** (win 320) |
| 05:47:34–37 | two more glitches @46 px (win 350–351) |
| 06:01:43 | frame 634's window opens, captures 6 frames — then the pipeline stops. |
| 06:01→07:49 | **Nothing.** `procMs` for window 634 records 285 s against a 108-minute wall gap — the monotonic clock stopped counting, i.e. **the app was suspended / device in deep sleep for ~103 minutes.** At thermal critical iOS forces the cool-down lock (seen in person on this device in Praha, 2026-08-23); a locked idle device then sleeps. It cooled to nominal doing nothing. |
| 07:49:59 | Device picked up → wake → frames flow. The stalled window 634 finally closes and **writes its 6:01 content with an 07:49 file date** (the "impossible" metadata — capture_log's `capturedAt: 06:01:43` is the truthful one). Backlog windows close empty in the catch-up storm and feed `consecutiveProcessingFailures`; frame 635 (indoors, mid-carry, correctly exposed — the camera came back in plain AE after the interruption) is flushed by the stop path. |
| 07:50:00 | `endReason: consecutiveProcessingFailures` — **one second after the run had just delivered a good frame.** |

So: **the OS ended this shoot at ~06:01 as thermal protection; our guard
only pronounced it dead 108 minutes later, on wake, for the wrong reason,
at the exact moment it had recovered.** Window advancement is frame-driven
(`captureOutput` closes windows as frames pass them) and the watchdog runs
on a monotonic clock — both freeze under suspension, so a suspended run can
neither die honestly nor resume cleanly.

Why ~30 minutes specifically: unthrottled on a 12 Pro is ~100 % duty
compute; nominal→fair in 7 min, →serious in 10, →critical in 16, OS
intervention at ~32. The iPad Air M1 ran the identical config at 85–90
frames/window for 2 h 17 m and **never left serious** (68 % of windows
serious, zero failures) — chassis and SoC headroom, not luck.

**Question 5 — yes.** This is exactly what **Blend: Safe • learned limit**
exists to prevent: the AIMD `ProcessingCeiling` holds blend depth at what
the device sustains (this same 12 Pro passed the killer bench conditions
under Safe: 289 windows, 0 failures, 0 self-stops). Unthrottled is the
stress/learning mode — and note it is also the *teacher*: every completed
unthrottled window on this run fed the learned profiles, so Safe on this
device now knows exactly what 68-frame windows cost. Unattended scheduled
shoots should not default to unthrottled on OIS-class phones.

**Fix direction (Question 4), layered — none of it touches capture
formats:**

1. **Honest lifecycle under suspension.** Detect the outage (session
   interruption notifications already fire and are logged; a wall-clock vs
   monotonic gap at wake is the unambiguous tell), write an `issues[]`
   entry with the real reason (`systemPressure`/interruption/suspension +
   gap length), and **never count backlog catch-up windows toward the kill
   guard** — the guard should judge live conditions only.
2. **Resume or end deliberately.** On wake either re-assert the ramp's
   custom exposure and continue (frame 635 proves the camera returns in
   plain AE — a resumed run is silently un-ramped), or end the run as
   `endReason: systemPressure` with a truthful endedAt. Either is
   defensible; a zombie is not.
3. **Stay out of critical.** The AIMD ceiling reacts to processing time;
   give it a **thermal input** (step the ceiling down hard at serious,
   floor it at critical) plus the already-planned starvation→repace
   (stretch the interval under pressure). The goal is that a 12 Pro
   unthrottled run degrades to a sustainable pace instead of summiting into
   the OS's veto.
4. **Truthful timestamps on late writes.** Frame 634's JPEG needs its EXIF
   `DateTimeOriginal` from `capturedAt` (it has it in capture_log and
   frames.timestamps; the file date will always be write-time — fine once
   EXIF is authored, per the open EXIF job).

## 4 · The 320→321 position jump (Observation 5)

Answered by the log — it is the **known OIS thermal-sag failure**, and the
2026-08-24 alignment gate caught it live: `framingGlitch` 44–46 px at
windows 319–351, thermal critical, then "framing moved and stayed — new
baseline adopted" (the lens sagged to its gravity stop and stayed while
critical). Same phone, same signature as Praha 2026-08-23 (~63 px there).

On the stabilization question: **digital video stabilization is OFF on the
frames we consume.** The only stabilization setter in the app targets
`movieOutput` (video recordings, user-toggled); the blend tap's
`AVCaptureVideoDataOutput` connection is never touched and its platform
default is off. What moved the frame is **optical** stabilization hardware
(lens suspension), which has no public off-switch on any iPhone — the
mitigations are the alignment gate (working), staying out of thermal
critical (§3), and iPads/sensor-shift bodies being immune. A one-line
hardening (explicitly pin `preferredVideoStabilizationMode = .off` on tap
connections and log it) is queued so the question never needs asking again.

## 5 · Tooling (Question 2)

**`tools/source_flicker_report.py <project>/source`** — the per-shoot
quality gate that replaces frame-by-frame eyeballing. Reads the source
JPEGs directly (no export needed), measures mean linear luma per frame
(same metric family as `flicker_report.py`), and reports two classes:

- **single visible steps** (>1/8 stop, same rule as the clip gate), and
- **oscillation events** — runs of ≥4 sign-alternating steps ≥0.05 stops.
  The alternation floor is deliberately *below* the single-step threshold:
  1a's flips are ~0.09 stops each — individually sub-visible, unmistakable
  as a pattern.

Each event is attributed from `capture_log.json`: the two-latched-states
exposure toggle (limit cycle), blend-count changes, thermal, and nearby
`issues[]`. Greppable verdict `SOURCE FLICKER PASS/FAIL`; ~5 s for a
2753-frame project. Validated today: 1b control PASS; 1a FAIL with every
event exposure-attributed; iPhone PASS-but-one (the single flagged step is
the 634→635 zombie seam, not servo flicker — which also confirms Comment 6:
the 12 Pro's ramp segment itself was clean). Framing integrity is *not*
this tool's job — that is `issues[]` + the alignment gate.

## 6 · Recommended order of work

1. **Ramp anti-oscillation** (deadband + dwell + hysteresis in the Kit) —
   smallest change, kills the most visible artifact, benefits DNG and JPEG
   alike, fully unit-testable, then bench-verifiable on the monitor test
   card's scripted brightness ramp before any dawn.
2. **Suspension-honest lifecycle** (backlog windows never feed the guard;
   outage → issues[] + honest endReason; deliberate resume-or-end) — turns
   the only critical fail into a recoverable or at least truthful event.
3. **Anchor drift toward AE + clip-aware meter** — the dark-dawn fix; the
   largest design surface, wants the test-card bench (scriptable light
   curve) for closed-loop validation before a real dawn.
4. **Thermal-aware ceiling + repace** — folds into the existing AIMD
   governor design note.
5. Small: stabilization pin on tap connections; EXIF `DateTimeOriginal`
   rides the existing JPEG-EXIF job.

**DNG safety, per the standing rule:** items 1 and 3 live in
`HolyGrailRampEngine`/metering policy — no bracket construction, no file
format, no `applyHolyGrailExposure` device-write changes; the DNG path's
explicit-value brackets and clamps are untouched, and the flicker gate plus
`testAConstantSceneNeverMovesTheRamp` regression-guard both pipelines. Item
2 is controller lifecycle (both blend controllers, mirrored), not capture.
Item 5 touches video-data-output connections only — the photo/DNG output
path has no such connection setting.

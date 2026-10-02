# Dynamic dusk on the 18 Pro main camera: the highlight guard froze the ramp and the shoot went ~4 stops dark (2026-10-02)

**Brief (Steven, 2026-10-02):** the first field run of the 2026-09-28
highlight guard. A Dynamic Interval shoot over Prague from just after sunset;
the preview grew noticeably dark and the shutter on the back of the phone was
faster than the light deserved. He stopped and restarted at once: the restart
opened on the exposure he expected the first run to have reached. Verdict:
the guard over-corrected.

**Projects:** run 1 `D49594CC-C856-460E-899F-465D39607B68` (1,083 DNG outputs,
16:50:48Z → 17:08:52Z, `endReason: user`), run 2 `AEA72AB8-4FF7-4FE7-9C9B-92480E46E7C1`
(105 outputs, 17:09:06Z → 17:12:23Z). **Device:** iPhone 18 Pro (iPhone19,2),
iOS 27.0, Back Camera (1× optical, physical, f/1.8), DNG, BLEND 3, EVERY 1 s,
`captureMode: dynamic`, landscape; build with 5746293. **Reference:** six 16 Pro
Photo-mode DNGs from the same spot (auto exposure), 16:56–17:07Z. **Evidence:**
both `capture_log.json`s, the phone's `Logs/console-20261002-184838.log` and run
1's frames 1, 374 and 1082 (pulled read-only over Wi-Fi).

## Verdict

The guard was in the build and drove the result; the two meters behaved —
the aim and the camera's own opinion tracked a plausible dusk (the restart's
camera exposure, EV 4.27, the 16 Pro's EV 4.0 at 17:07:46Z and the 18 Pro's
own AE, EV 4.40, agree). Three faults, all in the guard:

1. **A freeze.** At window 374 the guard raised its limit to EV 8.09 and the
   ramp stepped to EV 8.16 — 0.07 stop short, since its own want was smaller.
   The anti-flicker gate never makes a move under 0.12 stop; the guard only
   raised its limit from a reading shot within 0.05 stop of it. Neither could
   move again: 1/49 s, ISO 55 from 18:57:01 local to the end (frames 374 and
   1082 carry identical EXIF), while the aim fell 8.12 → 5.16 and, from ~19:00,
   nothing in the frame was near white. Reproduced on the engine: 700 windows,
   a 3-stop fall, no highlights → the exposure moved 0.000 stops. The
   2026-09-28 simulation could not show it: its fooled meter always asked for
   more than the limit, so the ramp always landed exactly on it.
2. **The drift paused all night.** It paused whenever the exposure was within
   ⅓ stop of a limit, i.e. for the whole shoot; the console logs the aim
   0.64–0.97 stop under the camera's own opinion every 100 windows.
3. **A threshold inside the camera's own rendering.** The camera's exposure
   leaves a lot of a dusk frame at white: 17 % at run 1's opening (a sunset
   sky), 8 % at white and 15 % within ⅓ stop at run 2's (lights, a glowing
   horizon), 9.4 % at the 2026-09-28 opening. An absolute "hold at 10 % within
   ⅓ stop of white" fired from window 2 of a healthy shoot (⅔ stop pulled down
   in 4 s) and held run 2 from its first window.

| local time | run 1 |
|---|---|
| 18:50:48 | Opens on the camera's exposure, EV 8.75; 17 % of the frame at white → ⅔ stop down in 4 s. |
| 18:51–18:57 | Held; the limit lifts ⅙ stop at a time as the sky dims, the ramp 0.1–0.3 stop behind its aim. |
| 18:57:01 | Frozen at 1/49 s, ISO 55 (EV 8.16), 0.07 stop under the limit. |
| 18:57–19:08:52 | Frozen for 12 minutes; aim −3 stops; frames 0 % near white from ~19:00. |
| end | 3.8 stops under the 18 Pro's AE; ~4.1 under the 16 Pro's AE 65 s earlier; 3.9 under the restart's opening 14 s later. |

**Checked against the frames themselves:** run 1's last frame, re-exposed in
the decoder, would have 14.1 % within ⅓ stop of white and 9.5 % at white at
the camera's exposure — run 2's live reading 14 s later was 14.8 % and 8.0 %.

## The fix (2026-10-02): a runaway net, relative to the opening

Steven's decision: the default guard is only a runaway safety net; protecting
a bright sky below the camera's exposure is the "Sky first" option's job.

- The opening is the least of the shoot's first three readings (the clipping
  the operator framed). Ten points more of the frame at white than that: no
  more light; twenty: step down ⅓ stop a window through the gate; within five:
  the limit sits at least ⅙ stop above the exposure those frames were shot at
  — from any reading, wherever the ramp has settled (the freeze).
- The drift pauses only while the frames show that excess or the net is
  actually holding the ramp back.
- The red "past the sensor's limit" is muted only while the net is holding.
- `hotFraction` is logged, not acted on. The opening rides each window's
  record (`highlightOpening`); `ramp_audit.py` prints it.

On tonight's frames the net would not have engaged: re-exposed in the decoder
to the camera's own exposure, frame 374 puts ~14 % at white and frame 1082
9.5 %, both under the 17 % the shoot opened with. The Kit simulations: the 2026-09-28 telephoto dusk still runs to
ISO 7,680 without the net and holds 0.8–0.95 stop over with it; a sunrise with
an honest meter is untouched; a sunrise whose meter cannot see the light rise
ends 6.7 stops over unguarded, 1.4 with the net (worst 23.7 % at white
against a 3 % opening). **Device check owed:** the 2026-10-03 sunrise.

Also seen: run 2 lost 91 of 196 windows — thermal serious, and three 0.3 s
frames plus processing do not fit a 1 s window (the TODO's interval and stack
ownership job, not exposure).

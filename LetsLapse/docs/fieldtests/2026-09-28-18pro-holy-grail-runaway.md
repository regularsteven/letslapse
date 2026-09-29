# Dynamic dusk on the 18 Pro telephoto: the ramp read its own ISO as nightfall and blew the shoot out (2026-09-28)

**Brief (Steven, 2026-09-28):** a Dynamic (Holy Grail) Interval shoot over
Prague at dusk on the iPhone 18 Pro. A red notification came up; then ISO
climbed "without limit" and, as the scene got darker, the footage got
*lighter*, ending completely blown out. The spec he expected: exposure is
limited, and past what the lens can do the picture goes dark — never blown.

**Project:** `E71A80FD-E847-42EB-A0DF-E294997F87D3` ("Holy Grail runaway";
352 DNG outputs + 39 empty windows, 17:07:33Z → 17:20:35Z, `endReason: user`).
**Device:** iPhone 18 Pro (iPhone19,2), iOS 27.0 (24A437), Back Telephoto
Camera (4× optical, physical lens, f/2.8), DNG, BLEND 5, EVERY 2 s,
`captureMode: dynamic`, landscape. **Evidence:** the project's
`capture_log.json` (per-window commanded / delivered pair, both meters, the
anchor), the phone's `Logs/console-20260928-165950.log` and
`liveblend-20260928-190733.ndjson` (pulled read-only 2026-09-28), and the
first and last output frames (`frame-00001.dng` on the Mac,
`~/Downloads/frame-00352.dng`). The 6 GB of originals were not needed.

## Verdict

The ramp drove the camera the whole time — every write applied, none clamped,
none refused, delivered EXIF = command within EXIF rounding. **It was fooled,
not bypassed.** Auto exposure never took over.

1. **Both meters stopped describing the scene once ISO carried the ramp.**
   The engine assumes its measurement is scene-referred (independent of the
   exposure it chose). Here the frames' APEX brightness (Bv) fell ≈ ⅔ stop per
   stop of ISO the ramp added, and the AE's "scene EV" (delivered pair +
   `exposureTargetOffset`) fell a full stop per stop — the offset stayed
   between −0.4 and −2.1 EV while the stills went ~7 stops over. Brighter
   frames read as a darker scene; the ramp answered with more ISO.
2. **The anchor drift supplied the push, with no limit on its total.** From
   window 178 the smoothed AE gap sat above the 0.25-stop deadband and the
   drift added 0.05 stop every window for ~100 windows: **+5.0 stops of
   calibration** (0.05 → 5.05). The trigger looks like EXIF rounding:
   `ExposureTime` is reported 1/n, so 0.73 s read as "1 s" and the AE's scene
   EV dropped a stop at that window (6.07 → 5.06) while Bv did not move.
   The drift's comment promised "≈ 1 stop per hour at 3 s"; 0.05 per window
   is a stop a *minute* at 3 s, 1.5 at 2 s.
3. **Nothing capped it but the lens.** There is no ISO/shutter policy
   ceiling in the code (the brief's "ISO 1600 / 15 s / 10 frames" was never
   built); the envelope is the active format's, and this telephoto's is
   ISO 15–7,680. The equilibrium the loop sought needs the meter to report as
   much over-exposure as the anchor demands; Apple's meter tops out at ≈ +3 EV
   over (Bv sat at exactly −5.24 for the last 90 windows: Av 2.97 + Tv 0 −
   Sv 11.26 = −8.29, so +3.05), and once the anchor passed that, no
   equilibrium existed and ISO ran to the hardware maximum.

## Timeline (from `capture_log.json`)

| run time | windows | what happened |
|---|---|---|
| 0:00–6:30 | 1–175 | 0.35–0.60 s at ISO 15. Both meters read ~1.1 stops of dusk in 6.5 min — plausible. |
| 6:30–7:00 | 176–188 | Shutter reaches its 1.0 s ceiling. AE scene EV drops a stop on the EXIF rounding; the drift engages. |
| 7:13–9:49 | 193–265 | **ISO 19 → 7,680 in 2.6 min.** Bv −6 stops, AE −9.3 stops, over a stretch of twilight that fell perhaps a stop. |
| 9:49 | 265 | ISO at the lens maximum. The run readout turns **red**: `1 s · ISO 7680 · EV −4.3 · past the sensor's limit` — the red notification. It lit at the END of the climb, not before it. |
| 9:49–13:00 | 265–352 | Pinned at 1 s × ISO 7,680; Bv pinned at −5.24 (the meter saturated). Frames blown: the last one renders the night-dark park as daylight foliage under a white sky. |

Also seen: after the shutter reached 1 s, windows held 1–2 of the requested
5 frames (a 2 s window fits one or two 1 s exposures) and 39 windows captured
nothing — the stack did almost nothing for night noise.

## Why this is not an 18 Pro bug

The failed property — "this measurement is independent of what the ramp just
did" — was assumed, never checked, and this is the third time it failed in a
new place (2026-08-15 iPad luma, 2026-09-04 12 Pro commanded pair, now Bv and
the AE offset). Each earlier fix swapped to a different device-supplied
number. The 18 Pro telephoto is simply the first run to drive ISO this deep
(the 16 Pro's deepest documented Dynamic run ended near 1 s / ISO 191).

## The fix (2026-09-28): a highlight guard on every ramped run

One rule, device-independent: **the ramp may not add light to frames whose
large areas are already at, or a step from, the sensor's white — and steps
back down when they are clipping.** It reads the pixels, not a meter.

- `HolyGrailRampEngine` keeps a ceiling in light gain: one step under an
  exposure whose frames had ≥ 10 % of the frame at white, at an exposure with
  ≥ 10 % within ⅓ stop of white; lifted ⅙ stop when a reading taken AT the
  ceiling shows < 5 % hot. Brightening never crosses it; above it the ramp
  steps down ≤ ⅓ stop a window through the gate. Readings carry the window
  and the gain their frames were shot at, so a late one is never answered
  twice. Near the ceiling the anchor may not drift toward more light. The
  red readout stays amber while highlights (not the sensor) hold the ramp.
- **DNG:** the blend already decodes each frame; the first frame's filter is
  rendered again with baseline exposure 0 at ⅛ size (~25 ms — the
  decompressed raw is cached) where 1.0 is the sensor's white. Not the
  blend's buffer: Core Image lifts this telephoto's Bayer frames +3.82 EV
  (their BaselineExposure) and folds highlights into a shoulder near 1.2 —
  on a real 18 Pro telephoto DNG the median scales ×14.2, the 99th
  percentile ×3.2, the brightest pixel ×1.3; a sample 1.8 stops under white
  reads 0.93. The baseline-free view is exactly linear (+1/+2/+4 EV pushes
  scale every percentile ×2/×4/×16). A fresh decode costs a whole decode at
  any scale (~950 ms for 48 MP on the M4 Max), so BLEND 1 pass-through
  windows measure at most every 4 s.
- **JPEG/HEIC:** the video tap's existing ~1,000-sample luma pass also counts
  highlights, against the output's own white (code ≥ 250 hot, ≥ 254 white).
- Logs: the guard's transitions and the red readout's text as console lines
  and `capture_log.json` issues (`highlights`, `readout`); per window the
  guard state, the reading, its window and peak, the ceiling as scene EV,
  and the device's exposure mode. `tools/ramp_audit.py` prints the guard.

**Verified off-device:** the Kit simulation of this night (compressing
meter, AE opinion that follows the ramp, the shipping drift and gate,
readings two windows late) runs to ISO 7,680 without the guard — the
failure reproduced from the mechanism alone — and with it holds the sky's
brightest third just under white while ISO follows the light (15 → 30 over
16 min), clipping ≤ 4 % of the frame. Kit suite green (the one failure is
the pre-existing `ShapeDetectionModeTests`); iOS and macOS Release builds.
**Not yet verified on a device** — see TODO "Holy Grail highlight guard".

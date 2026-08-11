# LetsLapse Test Card

A repeatable, hands-free timing ground truth for on-device capture testing.
Play `index.html` fullscreen on a monitor, point a tripod-mounted iPhone at
it, capture with LetsLapse, then run `../testcard_report.py` on the clip:
every captured frame carries its own display-side timestamp, so measured
fps, segment-switch gaps (ramp switches), and AE hold become direct
measurements.

## Quick start

```bash
# 1. Show the card (any browser; click for fullscreen)
open index.html

# 2. Shoot it with the phone on a tripod, then analyze the clip
cd ..
.venv/bin/python testcard_report.py report clip.mov

# Sanity-check the decode loop without a camera (headless Chrome renders
# frozen frames, the analyzer must decode them back to the exact times)
.venv/bin/python testcard_report.py selftest
```

Venv setup is the same as `capture_metrics.py`:
`python3 -m venv .venv && .venv/bin/pip install numpy opencv-python-headless`.

## URL parameters

| param | meaning |
|---|---|
| `?script=i25x100,b100x5,i25x100` | capture script encoded into the session QR (default shown) |
| `?t=12345` | freeze the card at elapsed ms — for testing/screenshots |

Script grammar (for the future app-side executor): comma-separated
segments, `i<fps>x<seconds>` = interval mode, `b<fps>x<seconds>` = burst.
Max ~100 chars (QR version 6 limit); the card shows `SCRIPT TOO LONG` if
exceeded.

## Channels (the machine-readable spec)

All geometry lives in a **1000×1600 logical card space**; the `LAYOUT`
constants in `index.html` are mirrored at the top of `testcard_report.py` —
**keep them in sync**. The analyzer builds a card→image homography from the
QR corner quads (cached across frames; the rig is assumed static).

| channel | format | role |
|---|---|---|
| Session QR | `LLTC1;<script>`, static | arms test mode, declares the capture script |
| Time QR | `LLT;NNNNNNNN` (ms, 8 digits), updates every 500 ms | coarse absolute time, wrap disambiguation |
| Gray strip | 18 blocks: black ref, white ref, then bit15..bit0 (MSB first) of the **Gray-coded 60 Hz tick counter** (`tick = ⌊ms·60/1000⌋`, wraps at 65536 ≈ 18 min) | primary fine time; one bit flips per tick so exposure blending costs at most ±1 tick |
| Sweep dial | 1 rev/sec, 0 ms at 12 o'clock, clockwise | sub-tick refinement (`card_ms_fine`); advisory — smears under long exposure |
| AE patches | grays 0/51/102/153/204/255, then R, G, B | exposure-hold measurement across cuts |
| Ball | constant-velocity triangle wave, x 150↔850 over 4 s period | visible motion for blend/warp seam inspection |

QR encoding is byte mode, EC level M, versions 1–6, standard penalty-scored
mask (a `forceMask` second argument on `QR.encode` exists as a debug hook).

## Analyzer notes

- **Requires `cv2.QRCodeDetectorAruco`** (OpenCV ≥ 4.8; falls back to the
  plain detector, but that one fails to decode ~25% of mask-7 symbols —
  verified empirically over 10,818 rendered codes, where the Aruco detector
  scored 100%).
- `report` writes a per-frame CSV (`card_ms`, `card_ms_fine`, `tick`,
  `sweep_ms`, `qr_ms`, patch lumas, `ball_x`, container `src_ms`) and prints:
  segment detection (windowed change-point on trimmed-mean intervals),
  per-segment fps from span/count with gap intervals excluded, a gap-event
  list (the ramp-switch holes), AE patch stability, and a container-clock vs
  card-clock slope.
- Segment rates use span/count, not median interval: strip times quantize to
  the 16.7 ms tick grid, so off-grid intervals (40 ms at 25 fps) read as
  alternating 33.3/50.0 ms per frame. That alternation is physics, not noise.
- VFR sources: for exact container PTS, extract frames via the
  `capture_metrics.py extract` recipe and point `report` at the directory.

## Physical setup

- All the rig displays are 60 Hz: the card cannot present a new state more
  often than every 16.7 ms. Capturing above 60 fps yields duplicate display
  states — capture *timing* is still measured (that's the point), but don't
  expect unique content per frame.
- Frame the card fully (corner brackets are the framing aid) at a distance
  where the chosen lens focuses comfortably; back off slightly if moiré
  appears on the QR modules.
- Monitor brightness high; beware PWM dimming on some panels (visible as
  banding at short shutter times).
- The strip survives motion blur and exposure blending; the sweep and QRs
  want shutter ≲ 1/100 s. If a run is purely about timing, locking AE/AF
  removes a variable.

## Simulated end-to-end run (no camera)

```bash
# render a fake capture (25 fps → 100 fps burst → 25 fps with holes at the
# switches) as frozen frames, then let report reconstruct it
for i in $(seq 0 39); do t=$((1000 + i*40)); ...; done   # see selftest for the
# Chrome invocation; or just trust `selftest`, which asserts the same loop
```

The analyzer was validated this way: a 110-frame synthetic sequence with
440/410 ms holes came back as `25.03 fps / 98.82 fps / 25.35 fps` with both
holes reported at the right frames and magnitudes.

## App-side integration (shipped, normal build)

`App/TestCardRig.swift` + `CameraController.startTestCardTap/stopTestCardTap`.
While the capture screen is idle in **Video** mode, a sparse (2/s) preview
tap runs Vision QR detection. The rig locks when it decodes the session QR
**and** sees the time QR advance across two reads (a *photo* of a card never
arms), shows a 3 s countdown chip (tap cancels), then runs the script through
the real ramp engine — `selectFrameRate(base)`, `selectRampFrameRate(burst)`
(validated against the capability matrix; refused loudly if unreachable),
`startRecording(mode: .ramp)`, `triggerTimedLiveMoment(duration:)` per `b`
segment — and stops itself. Tapping the chip mid-run stops and keeps the
partial take. Finished runs cool down 20 s before the rig can re-arm.

It ships in the normal build by decision (testing must be no-fuss); the guard
rails are behavioural — `LLTC1;`-only arming, the live-clock requirement, the
visible cancellable countdown, and the cooldown. `LL_TESTRIG=chip` freezes a
demo countdown chip for design screenshots.

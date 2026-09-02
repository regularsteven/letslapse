# Framing shift under thermal load — cross-project pattern (2026-09-02)

**Brief:** on the iPhone 12 Pro, wide camera, the framing steps ~50 px
vertically once the device is hot; every later frame is misaligned with the
earlier ones. Suspected cause: the lens-shift OIS actuator being parked by
the system, which no AVFoundation setting controls.

**Method:** a new tool, `tools/framing_shift_report.py`, was run over every
project on `/Volumes/letslapse/Projects` that has JPEG source frames
(28 projects, ~17 k frames, ~1 min). Per frame it phase-correlates the
luma against the previous frame (whole frame, 1/4-scale draft decode),
integrates the steps into an offset from the run start, reads the EXIF
f-number and pixel dimensions, and joins each step to `capture_log.json`
(thermal state at window open/close, blend count, alignment-gate tallies,
`issues[]` within ±2 windows). Raw output: `2026-09-02-framing-shift-sweep.txt`.

## Result

| population | frames | stayed steps |
|---|---|---|
| iPhone 12 Pro at nominal | 1474 | 0 |
| iPhone 12 Pro at fair | 513 | 0 |
| iPhone 12 Pro at serious | 2653 | 0 |
| **iPhone 12 Pro at critical** | **2856** | **6 (4 projects)** |
| iPhone 16 Pro, nominal → serious (never critical) | 2766 | 0 |
| iPad Air M1 (no OIS), up to serious | 5226 | 0 |

Every step in the whole corpus is on the 12 Pro and lands in a window whose
thermal state is **critical**. In all three post-gate projects
(F6F7FCC8, 8B6C7BFC, FC69DAEB) the step sits in the very window in which the
`serious → critical` transition was logged, i.e. within 2–3 s of the OS
crossing the line. The user-reported "fair or serious" onset is not
supported: at serious the phone captured 2653 clean frames.

Per step: 44–64 px along the stored height (world-vertical in both portrait
and landscape storage), ≤ 0.4 px horizontal, identical f-number (1.6, the
wide) and pixel dimensions on both sides, engine records clean. Top,
middle and bottom thirds of the frame move by the same amount within 3 px
(−57.3 / −59.0 / −60.6 px on F6F7FCC8 484→486; left and right halves
−59.3 / −60.1), so it is a translation, not a zoom, crop or distortion
change. The slight top-to-bottom gradient is consistent with a small lens
tilt riding along with the drop, and is nothing a format or crop change
could produce.

The lens also **re-centres**: F6F7FCC8 frame 790 returns to the run-start
framing for exactly one frame and re-sags at 791; E9D52934 has two
one-frame excursions (18, 205) that return to sub-pixel baseline. In deep
stacks a partial sag ghosts instead of stepping (E9D52934 windows 128–132:
correlation response 0.37–0.48 against ~0.73 either side, zero measured
shift) — the alignment gate now removes those frames.

Sanity check on the magnitude: 60 px of a 4032-px frame on the 26 mm-equiv
wide is ≈ 0.9°, inside a lens-shift OIS actuator's travel. A spring-
suspended lens whose coil is de-energised drops to its gravity stop; that
is exactly a gravity-aligned, fixed-size, repeatable step with occasional
one-frame recoveries.

## The brief's four steps

1. **Geometry across the jump — constant.** Dimensions and f-number are
   per-frame constant; `captureWidth/Height` is per-session constant; the
   step is a uniform translation. By the brief's decision rule the shift is
   optical, not software. (Per-frame `videoFieldOfView` / `videoZoomFactor`
   / GDC are not logged today; the pixels rule each of them out — a zoom
   or FOV change scales, GDC warps the edges and crops, neither translates
   uniformly.)
2. **Implicit stabilization — none on these frames.** The only
   `preferredVideoStabilizationMode` write in the app is on
   `movieOutput`'s connection (`applyVideoStabilization`, video mode).
   The blend tap is an `AVCaptureVideoDataOutput` whose connection is
   never given a mode (default `.off`); stills through the photo output
   carry no EIS. Nothing is toggled on preset/format/mode changes for
   those outputs. The TODO job to pin `.off` explicitly and log it stands.
3. **Lens switching — locked and observed.** Runs lock
   `primaryConstituentDeviceSwitchingBehavior` to `.locked` at start
   (2026-08-24); a KVO on `activePrimaryConstituent` writes a
   `constituentSwitch` issue on any hand-off. None in any affected log, and
   the per-frame f-number never leaves 1.6.
4. **Geometric distortion correction — never touched.** No reference to
   `isGeometricDistortionCorrectionEnabled` anywhere in the codebase; the
   system default applies for the whole run.

## What the corpus cannot say yet

- **16 Pro at critical:** never reached in any logged run (peak serious,
  116 frames). Its sensor-shift stabiliser is *plausibly* immune; not
  proven.
- **Physical-wide vs virtual triple on the 12 Pro:** every affected run
  was on `Back Triple Camera` (JPEG Dynamic). The 12 Pro "Back Camera" and
  tele runs in the corpus have no JPEG sources (DNG), so were not measured.
  The physical wide has the same OIS actuator, so pinning it is not
  expected to help — but it is untested.
- **Shoot type:** every affected run was Dynamic (Holy Grail ramp), and so
  was every 12 Pro run that reached critical. Interval runs on the 12 Pro
  never got past fair in this set. Thermal state is the discriminator;
  shoot type is confounded with heat.
- **Critical is necessary, not sufficient:** CBD2B71A spent 67 windows at
  critical with no step.

## Mitigation directions (not built — the brief asked for cause first)

There is no API that controls the OIS actuator, so nothing in our capture
configuration can prevent this. Options that respect the no-reframing rule:

- **Keep the 12 Pro out of critical.** Screen dimming (shipped) bought
  ~14 min at critical on the bench but the sag arrives at the transition,
  so the aim is not entering it: the queued thermal input to the AIMD
  ceiling, cold starts, and warning on unthrottled/Dynamic for OIS-class
  phones in scheduled shoots.
- **Detect and surface.** The gate already writes `framingChanged` at the
  step; the capture screen and the project's Field Notes could show it
  (the TODO tie-in job). A per-frame measured-offset sidecar from this
  tool would let the editor *show* the misalignment without correcting it.
- **Pause at critical on OIS-class devices** as an opt-in shoot policy —
  since the lens re-centres when the servo returns, frames after recovery
  realign. Trade-off: F6F7FCC8 stayed critical for 969 windows, so pausing
  is pausing for the rest of a hot shoot.
- **Bench confirmation** on the test-card rig: heat a 12 Pro to critical
  on a static scene with (a) the virtual triple and (b) the physical wide
  pinned, and a 16 Pro driven to critical; run this tool on the pulls.

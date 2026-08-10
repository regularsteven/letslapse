# Capture Optics — groundwork spec

**Date:** 2026-08-04
**Status:** Groundwork **validated on hardware** (probe runs: iPhone 16 Pro + iPad Air M3, same day — reports in `capture-baseline/optics/`). Next: design files → implementation. Follows the Capture Experience Investigation (`capture-experience-investigation.md` §2/§8, Stage 2); supersedes that report's open questions 1 and 6.

## Decisions (Steven, 2026-08-04)

1. **Native optical stops are always shown** and are always derived from hardware at runtime — never hardcoded factors or labels.
2. **Computational 2× stops** are derived from whatever native lenses exist ("2× of whatever native lens is available"), except stops that duplicate an existing lens — the ultra-wide is never doubled, because 2× of 0.5× is the 1× lens.
3. Computational stops are **on by default** (matches native Camera on Pro iPhones and Indigo on iPad Air) and can be hidden in **Settings → Capture Optics**.
4. Devices degrade honestly: a single-lens iPad Air shows 1× + 2×; a dual-camera device shows its optical stops + their 2×; an iPhone 16 Pro shows 0.5 / 1 / 2 / 5 / 10.
5. **Switching is the ramp, not the dissolve** (investigation §3 recommendation, confirmed).
6. Prefer **native sensor crops over digital upscaling wherever the hardware offers them** — "optimisation in mind".

## The derivation rule

Implemented executable in `App/CaptureOpticsProbe.swift` (`CaptureOpticsDerivation.derive`) so the probe report *is* this rule running on real hardware:

1. **Capture device**: first available of `builtInTripleCamera` → `builtInDualWideCamera` → `builtInDualCamera` → `builtInWideAngleCamera` (rear). Physical-wide fallback covers single-lens devices and the Mac.
2. **Native stops**: the widest constituent, plus one stop per `virtualDeviceSwitchOverVideoZoomFactors` crossing. Labels formatted from the actual display factor — never a constant.
3. **Sensor-crop stops**: every factor in the formats' `secondaryNativeResolutionZoomFactors` (the quad-Bayer binned crop — e.g. the 48 MP main's 2×). Full-quality crops, no upscaling.
4. **Digital 2× stops**: for each native stop at display ≥ 1× (this floor is what keeps the ultra-wide from doubling), its double — dropped when a stop already exists within 5% (which is how 2×-of-1× yields to the sensor crop when the sensor has one), and when it exceeds `videoMaxZoomFactor`.
5. Sort ascending; each stop carries a kind: `optical` / `sensor-crop` / `digital-2x`. The kind drives the badge treatment (design stage) — the user must be able to tell optics from pixels.

### The factor-space trap (implementation-critical)

On virtual devices, `videoZoomFactor` is relative to the **widest constituent**: on a triple camera, display 1× = raw 2.0, display 5× = raw 10.0, and `secondaryNativeResolutionZoomFactors` values arrive in the same raw space. The display divisor is the raw factor at which the wide-angle constituent becomes primary (1.0 when the widest constituent *is* the wide). Every chip label, persistence value, and Settings row uses **display** factors; every AVFoundation call uses **raw**. The probe prints both columns per stop precisely so this mapping gets validated on hardware before any chip renders.

## Chip sets per device

| Device | Chips (kind) | Status |
|---|---|---|
| iPhone 16 Pro (iPhone17,1) | 0.5× · 1× (optical) · 2× (sensor-crop) · 5× (optical) · 10× (digital) | ✅ **probe-confirmed** — switchovers [2, 10], crop factor [4] on 45 formats, exactly as predicted |
| iPad Air M3 (iPad15,5, single wide) | 1× (optical) · 2× (digital) | ✅ **probe-confirmed** — no native crop on the 4224×3168 sensor |
| iPad Air M1 | 1× (optical) · 2× (digital) expected | probe run optional (same class as M3) |
| iPhone 17 Pro class (48 MP tele) | 0.5× · 1× · 2× (crop) · 4× (optical) · 8× (crop) — same rule, zero code changes | predicted |
| Base iPhone 16 class (dual-wide) | 0.5× · 1× (optical) · 2× (crop) | predicted |
| iPhone 15 Pro class (3× tele) | 0.5× · 1× · 2× (crop) · 3× (optical) · 6× (digital) | predicted |
| Mac | 1× only → chips hidden (unchanged behaviour) | by construction |

### Probe findings worth keeping in mind (2026-08-04 runs)

- **Model identifiers**: iPhone17,1 *is* the iPhone 16 Pro (identifiers run ahead of marketing names). The probe's topology is definitive: 12 MP tele (4032×3024) at raw switchover 10 = display 5×.
- **The 16 Pro's ultra-wide is also 48 MP** (8064×6048). Its 2× binned crop would land at display 1× — a duplicate of the wide lens, which is exactly why the rule never doubles the ultra-wide; the hardware's advertised crop factor list ([4], display 2×) agrees.
- **Constituent switching is condition-based**: in the 16 Pro walk the tele stops reported `WideAngleCamera` as the backing camera — with `auto` switching the system engages the tele only when subject distance and light allow, and covers 5× from a wide-sensor crop otherwise (native Camera does the same). Not a mapping bug; the probe now logs the switching behaviour and suggests re-running aimed at a bright distant subject.

  ~~Implication for the ramp: constituent choice belongs to the system, and the FOV the user sees at each stop is correct either way.~~ **Overturned 2026-08-06.** The FOV is correct either way; the *lens* is not, and across a multi-segment run that is the whole problem. A 4K 5× ramp shoot (project `10DD1859`) recorded segment 000 on the tele, the 100 fps burst as a 5× crop of the wide (the physical-only rate swaps the session to the physical wide by design), and segment 002 as a ~9× crop of the ultra-wide for its full 39 s — each segment's `activeFormat` switch resets `videoZoomFactor` to 1, i.e. the ultra-wide, and `startNextSegment` starts the movie output straight into the hand-off back up. Measured: two reframes (the first a clean 6.7%-of-frame-width translation, no scale change — the lenses' optical axes), and a detail collapse of 35 dB → 41 dB → 49 dB (frame vs. its own 1.2σ blur; higher = less real detail). Constituent choice belongs to the system *between* runs; within one it has to be pinned, which is what `pinLensForSequence` now does.

Quality note stated honestly in-product where relevant: sensor-crop stops cost nothing but the crop; digital-2× stops are upscales (Indigo's iPad 2× is multi-frame super-resolution — out of scope here; ours is a plain crop-upscale and is badged as enhanced, not optical).

## Mode interactions

- **Video + Interval/Photo JPEG**: zoom factor applies to the stream and processed stills — computational stops work in all of these.
- **DNG-armed capture (Photo/Interval · DNG)** — **question resolved by the probe**: on the iPhone 16 Pro the virtual Triple Camera offers **no Bayer RAW at any stop** (`availableRawPhotoPixelFormatTypes` empty throughout the walk), while the iPad's physical wide device offers `rgg4` — so plain Bayer RAW is a physical-device capability, and **DNG capture keeps a discrete-device session** (today's architecture) with the investigation's single-transaction + exposure-seeding + freeze-cover fallback for its lens switches. DNG mode therefore offers **optical stops only**, disabled computational chips with the app's honest-degradation pattern. On single-camera devices (iPads) nothing changes — the physical device is the only device, and it has RAW. (Apple ProRAW does exist on virtual devices, but it is a demosaiced, Apple-processed linear DNG — a different pipeline entirely from the app's Bayer mosaic blending; not a substitute.)
- **Mid-run**: lens stops stay locked during runs (existing policy, unchanged by this spec); post-ramp, mid-recording zoom in Video mode remains a separate open decision (investigation §9 Q3).

## Settings → Capture Optics (groundwork outline; final form is the design stage's)

- One toggle: **Enhanced lenses** — shows/hides every non-optical stop. Default **on**.
- Below it, an informational list of *this device's* stops with kind labels, in the manage-resolutions visual pattern (native rows fixed, no per-stop toggles in v1 — the single switch matches how Steven described it; per-stop hiding can arrive later if wanted).
- Persistence: replace `RecordingSettingsStore.lens` (enum token) with the remembered **display factor**; migrate old tokens (`ultraWide` → 0.5, `wide` → 1.0, `telephoto` → the device's tele stop) so a remembered setup survives the upgrade.

## Ramp (locked decision, lands with the model)

Chips become zoom targets on the one virtual-device input: `ramp(toVideoZoomFactor:rate:)` through switchovers, system-managed constituent handoff and AE carry-over, continuous imagery throughout. The stepped pinch becomes a continuous zoom (chips highlight by nearest band, native-style). No session transaction on any stop change. Cold start/resume keep the freeze-frame cover from the investigation plan; dissolve is otherwise dead.

## Validation workflow — status

1. ✅ Probe run on iPhone 16 Pro and iPad Air M3 (2026-08-04); reports in `capture-baseline/optics/`. iPad Air M1 optional (same single-camera class as the M3).
2. ✅ Both derived sets match the predictions; the rule stands unchanged. RAW-on-virtual resolved: **no** — DNG stays on discrete devices (see Mode interactions).
3. ✅ **Implemented 2026-08-04** (Steven's call: skip the SVGs for now, test on device — mirrors owed later per the design-sync contract). `CameraController` runs the optics device (virtual multi-cam) with `ramp(toVideoZoomFactor:rate:8)` stop changes; chips derive from `CaptureOpticsDerivation`; enhanced stops carry a placeholder dot; DNG work (armed framing + runs) swaps to the stop's physical constituent and back, optical stops only; "Enhanced lenses" toggle in Settings (default on); remembered lens migrates to a display factor (legacy `telephoto` → 4.0 → nearest tele stop). Installed to the iPhone 16 Pro and iPad Air M3.
4. **On-device verification next**, then re-measurement with `tools/capture_metrics.py` against the §5 acceptance table (a fresh §2 baseline recording from the iPhone 16 Pro validates the harness first). SVG mirrors for the chip strip, DNG-armed state, and the Settings row are owed once the design settles.

*Design-sync note: `CaptureOpticsProbe.swift` and its Settings row are diagnostics tooling, deliberately outside the SVG contract (stated per the "or state why no SVG applies" rule).*

# JPEG Holy Grail: locked white balance, and the EXIF that was never written

**Raised:** 2026-08-23 · **Jobs A + B implemented 2026-08-23 (device verification pending)** · Evidence: field shoot `jpeg sunrise`

> **Status update (2026-08-23).** Implemented on `ios-app`, together with the
> Capture Flat jobs ([capture-flat-jpeg-brief.md](capture-flat-jpeg-brief.md)):
>
> - **Job A** — §7's option 3, the slew-limited gains. JPEG-pipeline runs now
>   hold `setWhiteBalanceModeLocked(with:)` gains that track an EMA-smoothed
>   `grayWorldDeviceWhiteBalanceGains` signal, capped at 0.01 log2 per channel
>   per window (`applyHolyGrailTrackedWhiteBalance`, `CameraController`). The
>   seed is AWB's settled answer at arm — the same gains the old `.locked`
>   froze — so a run opens identically and diverges only as the illuminant
>   moves. Within a window the gains never move at all. **The C2 trap is
>   honoured with an explicit flag**: `beginHolyGrailForBlendRun` now takes
>   `rawPipeline:` (the controller references and `holyGrailRawPixelFormat`
>   are both assigned *after* it runs, so neither could answer during the
>   seed's first write), and the DNG pipeline keeps the plain `.locked`
>   statement untouched.
> - **Job B** — the blended-JPEG write site authors EXIF + TIFF from
>   `record.exposure` (ISO, ExposureTime, FNumber, DateTimeOriginal +
>   Subsec + OffsetTime, device identity), GPS alongside as before.
>   `brightness`/`sceneExposureProvider` was NOT touched — it feeds both
>   pipelines (C2), so BrightnessValue is simply absent until someone
>   deliberately does that work.
> - **Job C** — not actioned, per its own instruction.
>
> Verification per §8 is still owed: a dawn/dusk JPEG arm (WB must track,
> EXIF must be present, `flicker_report.py` must pass) and an unchanged DNG
> arm diffed against a pre-change run.

This brief is self-contained. It assumes no knowledge of the conversation that
produced it. Read the **Constraints** section before writing any code — this job
has a hard scope boundary that is easy to cross by accident.

---

## 1. The shoot that produced this

| | |
|---|---|
| Project (this Mac) | `98C4542D-506F-4E74-9404-C308B7A32BAD` |
| Project (device) | `98F1395D-42C7-4EE8-8107-E96AAEBE47FF` |
| Name | `jpeg sunrise` |
| Device | iPad Air (5th gen), `iPad13,16` — registry alias `ipad-m1` |
| Mode | `Interval · JPEG · Psycho blend`, 3 s interval, `blendMode: unthrottled` |
| Window | 2026-08-23 **05:06:01 → 07:09:40 local** (Prague, CEST; the log is UTC) |
| Duration | 2 h 03 m, 2473 frames |
| Sunrise | ≈ 06:00 local — the run starts ~52 min before and ends ~70 min after |

Files (all local, no device needed to re-verify):

```
~/Library/Application Support/LetsLapse/Projects/98C4542D-506F-4E74-9404-C308B7A32BAD/source/
  frame-00001.jpg … frame-02473.jpg
  capture_log.json      # per-frame ev / iso / exposureDuration / blendCount / window stats
  frames.timestamps     # the ramp's own sidecar: its TARGET shutter/iso and smoothedEV
```

Note `sourceFileNames` in `library.json` lists 2474 entries: 2473 `.jpg` plus
`source/frame-02474.json`. The index's final "frame" is a JSON file, not an
image. Harmless here, but it is a real oddity and nobody has explained it.

**The operator's report:** the start is correctly metered for colour
temperature; the end is a disaster. It also gets darker despite the sunrise.
Both reports are accurate. They have **different causes**, and only one is a bug.

---

## 2. Finding 1 — white balance is locked for the entire run

This is the show-stopper.

[`applyHolyGrailExposure()`](../App/CameraController.swift#L5403) —
`App/CameraController.swift:5403`:

```swift
if device.isWhiteBalanceModeSupported(.locked) {
    device.whiteBalanceMode = .locked          // ← no gains argument
}
device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
```

`whiteBalanceMode = .locked` with no gains freezes WB at **whatever AWB had
settled on at the moment of the first call**. That call is
`beginHolyGrailForBlendRun` (`CameraController.swift:5441`), i.e. the instant the
run arms — 05:06, under sodium streetlights. It is then re-asserted every window
from `rampHolyGrailBlendWindow` (`CameraController.swift:5306`).

**Nothing restores AWB until the run ends.** The only restore in this path is in
[`endHolyGrailIfActive()`](../App/CameraController.swift#L5498)
(`CameraController.swift:5498`). The three other `continuousAutoWhiteBalance`
restores in the file belong to the switch-exposure-hold release (`:3123`), the
user-initiated `unlockExposureAndFocus()` (`:3628`), and scanner end (`:6453`) —
none of them fires during a Holy Grail interval run.

So the shoot renders 2 hours of changing illuminant through gains fitted to
sodium vapour.

### Measured consequence

| | frame 1 (05:06) | frame 2473 (07:09) |
|---|---|---|
| R/G | 1.310 | **0.145** |
| B/G | 0.715 | **2.238** |
| linear mean R | — | 0.00020 |
| linear mean B | — | 0.13242 (**662× red**) |
| red p99 | — | **14 / 255** |

An hour after sunrise, a stone building renders cyan. Red occupies about 14 of
255 code values, so it is **quantised away before the JPEG is encoded** — a
gray-world correction applied afterwards produces posterised red blotches, not a
recovered image. This is not recoverable in post, which is exactly why it is a
show-stopper for JPEG and not for DNG.

### What is NOT the lock — do not chase this

There is a sharp step in R/G at 05:48 (frames 840 → 842, `0.185 → 0.105`) that
looks like a lock event and is not. It is the **city streetlights switching
off**:

- the change is region-graded — street `×0.29`, lower building `×0.42`, upper
  building `×0.80`, sky `×0.94`. A global WB gain change would scale every
  region identically.
- warm-bright pixel count goes `1450 → 0`; red's channel maximum goes `255 → 143`
  (the lamp cores were the only 255-red pixels).

It coincidentally lands within two frames of `blendCount` saturating at its
ceiling of 72, which makes it look causal. It is not.

---

## 3. Finding 2 — the darkness is the anchor, not a runaway

**Read this section before "fixing" the ramp. The ramp is not broken.**

### A measurement correction, recorded so it is not repeated

An early pass in this investigation measured frame brightness with Rec.601
weights on **gamma-encoded** JPEG values and concluded the run drifted ~1.6
stops and ended ~5 stops underexposed. **That was wrong.** Measured the way the
ramp actually measures — [`meanLinearLuma`](../App/LiveBlendController.swift#L566)
(`LiveBlendController.swift:566`): Rec.709 weights, `pow(channel, 2.2)` — the run
is essentially flat:

```
05:06   0.03308    0.00 stops
05:56   0.03242   -0.03
06:36   0.03024   -0.13
07:09   0.03044   -0.12   ← total drift, 2 hours, ~15 stops of light change
```

The regulator held to **0.12 stops**. The delivered exposure also tracked the
ramp's commanded exposure to within 0.15 stops for the whole run (compare
`frames.timestamps` against `capture_log.json`). There is **no runaway** and the
iPad obeyed every write.

### Why it is dark anyway

Two defaults, both in
[`HolyGrailRampEngine`](../Kit/Sources/LetsLapseKit/HolyGrailRampEngine.swift):

- `anchorsToSeedExposure: Bool = true` — the first measurement *defines*
  "correct" and the ramp holds that brightness for the rest of the run.
- `bias: Double = 0` (`CameraController.swift:716`, passed at `:5467`).

Seeded at 05:06 on a night street, the anchor sat **2.44 stops below mid-grey**.
A faithful ramp then holds exactly that. **Sunrise therefore cannot brighten the
image — holding one grey is the designed behaviour.** The engine's own `bias`
documentation names this: *"keeps the ramp from flattening the whole shoot to
the same grey."*

### But the WB bug makes it measurably worse

Blue's share of the metered luma rose from **3.5% at the seed to ~31% at the
end** (neutral would be ~7.2%). The ramp regulates *total* luma, so with blue
inflated by the stale gains it must push R and G down to compensate. Estimated
at roughly **−0.4 stops** of additional real-scene darkening that exists purely
to offset the white-balance error.

**The two faults are coupled: the locked WB corrupts the very signal the ramp
meters.** Fixing WB will move the exposure the ramp chooses. Expect that, and do
not read it as a regression.

Whether the anchor default is right for a sunrise is a **separate product
question**. It is explicitly *not* in scope here. Do not change `bias` or
`anchorsToSeedExposure` as part of this job.

---

## 4. Finding 3 — the JPEG path has no scene-referred meter

There are two metering routes into the ramp, chosen by capture pipeline:

| Path | Controller | Measurement | Scene-referred? |
|---|---|---|---|
| **DNG** | `LiveBlendRawController` (`CameraController.swift:7108`) | `.apexBrightness` | **Yes** — safe |
| **JPEG** | `LiveBlendController` (`CameraController.swift:6909`) | `.luma` | **No** — self-referential |

The `.luma` route computes
(`CameraController.swift:5262`):

```swift
measuredEV = sceneEV100(forGain: gain(shutter, iso)) + log2(luma / 0.18)
```

Both [`LiveBlendController.swift:300`](../App/LiveBlendController.swift#L300) and
[`CameraController.swift:5230`](../App/CameraController.swift#L5230) carry
warnings that this is the route that *"walked a real shoot 9.7 stops into its
shutter floor on 2026-08-15"* — on this same iPad. `defaultTrendSmoothing` was
set to `0.0` as a result.

It **held** on this run (0.12 stops), so this is not an active fire. It is
recorded because it is the structural reason the JPEG path is the fragile one,
and because the WB contamination above enters the ramp *through this route*.

A third, unused option already exists and is fully documented:
`HolyGrailMetering.sceneEV100(shutterSeconds:iso:aperture:exposureTargetOffset:)`
at `Kit/Sources/LetsLapseKit/HolyGrailRampEngine.swift:383`. It uses
`device.exposureTargetOffset` — AE's own opinion of how far the current exposure
sits from its target — precisely to break the self-reference. Nothing calls it
from either blend path today.

---

## 5. Finding 4 — EXIF is never authored on the JPEG path

The operator's constraint is that EXIF must not be stripped. **Nothing strips
it.** It is never written in the first place.

[`LiveBlendController.swift:786`](../App/LiveBlendController.swift#L786):

```swift
let metadata = configuration.gpsMetadata?().map {
    [kCGImagePropertyGPSDictionary: $0 as Any]
}
try ImageExporter.write(image, to: url, format: .jpeg, metadata: metadata)
```

Only a GPS dictionary is passed. `ImageExporter.write`
(`Kit/Sources/LetsLapseKit/ImageStacker.swift`) merges whatever it is handed into
the destination properties and discards nothing — so the omission is entirely at
the call site. Verified against the delivered files: `frame-00001.jpg` carries
only `ColorSpace`, `ExifImageWidth`, `ExifImageHeight` and a GPS block. No
`DateTimeOriginal`, no `ExposureTime`, no `ISOSpeedRatings`, no `FNumber`,
no `BrightnessValue`.

**Everything needed is already in scope at that line.** `WindowRecord.exposure`
(`LiveBlendController.swift:356`) is a `DNGAuthor.DNGExposure`, whose fields are
declared with their EXIF tags:

| Field | EXIF tag | Populated today? |
|---|---|---|
| `iso` | 34855 ISOSpeedRatings | yes |
| `exposureDuration` | 33434 ExposureTime | yes |
| `aperture` | 33437 FNumber | yes |
| `capturedAt` | 36867 DateTimeOriginal | yes |
| `brightness` | 37379 BrightnessValue | **no — always `nil`** |

`brightness` is nil because
[`sceneExposureProvider()`](../App/CameraController.swift#L6743)
(`CameraController.swift:6743`) never sets it. Note also that the three fields it
*does* set are read from `device.*`, which during a Holy Grail run are the
ramp's own commanded values — so this record is **not** a substitute for a
scene-referred meter. It is good enough for EXIF; it is not good enough for
Finding 3.

`ImageExporter.carryoverMetadata(from:)` already does the right thing (EXIF +
GPS + TIFF, minus orientation) but takes a **source URL**, and the live-blend
path has no source file — its frames are in-memory pixel buffers off the video
tap. So this needs authoring, not carrying over.

**Asymmetry worth knowing:** the DNG path *does* write a real EXIF IFD
(`Kit/Sources/LetsLapseKit/DNGAuthor.swift:506`). JPEG is the one without.

---

## 6. Constraints — the scope boundary

These come directly from the operator and are not negotiable without going back
to them.

### C1. Do not strip EXIF; author it on the JPEG blend output.

### C2. This work changes the **JPEG** strategy only.

DNG capture must be unaffected **unless a specific finding justifies otherwise**,
and that justification must be raised before it is acted on.

> **The trap.** `applyHolyGrailExposure()` — the function holding the WB lock —
> is **shared by both pipelines**. It is reached from
> `rampHolyGrailBlendWindow()` (`CameraController.swift:5306`), which is called
> by the RAW controller's `onWindowOpened` *and* the standard controller's, and
> from `beginHolyGrailForBlendRun()` (`:5441`), used by both. **A naive edit to
> line 5403 silently changes DNG behaviour.** Any change here must be
> conditioned on the active pipeline.

### C3. WB locking is *acceptable and wanted* for DNG.

RAW carries the full grading latitude, so a frozen illuminant is recoverable in
post and the stability is a feature. For JPEG the gains are baked into 8-bit
output and the red channel is destroyed — hence show-stopper. **The fix is a
divergence in behaviour between the two pipelines, not a global change.**

---

## 7. Suggested shape of the work

Not prescriptive — the next agent should confirm each of these against the code
before committing to an approach.

### Job A — stop JPEG runs freezing white balance (the show-stopper)

Gate the WB lock in `applyHolyGrailExposure()` on the pipeline. Candidate
approaches, roughly in order of increasing ambition:

1. **Leave AWB continuous for JPEG.** Simplest. Risk: per-window AWB drift shows
   up as colour flicker across the sequence — the very thing the lock prevents.
   Must be measured, not assumed.
2. **Re-assert `deviceWhiteBalanceGains` per window** rather than `.locked`, so
   the gains track the scene but are stable within a window. Note
   `applySwitchExposureHold` (`CameraController.swift:3093`) already demonstrates
   the clamp-to-`maxWhiteBalanceGain` pattern this needs.
3. **Slew-limit the gains** — the WB analogue of the ramp's 1/3-stop-per-step
   limit, tracking the illuminant without stepping visibly.

Whichever is chosen, the DNG path must come out byte-identical in behaviour.

### Job B — author EXIF on the JPEG blend output

At `LiveBlendController.swift:786`, build a full EXIF dictionary from
`record.exposure` alongside the existing GPS block. Also populate `brightness`
in `sceneExposureProvider()` (`CameraController.swift:6743`) if a
scene-referred APEX value can be obtained there — but see C2: that provider
feeds **both** pipelines, so adding a field to it touches DNG's records too.
Confirm that is inert before doing it.

### Job C — (record only, do not action without a decision)

Give the JPEG path a scene-referred meter via the existing
`sceneEV100(…exposureTargetOffset:)`. This is the structural fix for Finding 3.
It is **not** required to resolve the operator's two complaints and it changes
ramp behaviour, so it should be a separate, separately-verified job.

---

## 8. How to verify

**Re-verify the findings without a device** — everything is in the imported
project. Use the analysis venv (`LetsLapse/tools/.venv/bin/python3`, has
numpy + opencv + PIL):

- WB collapse: mean R/G and B/G per frame across the run.
- Ramp health: `meanLinearLuma` (Rec.709 + `pow(x, 2.2)`) — **not** Rec.601 on
  encoded values.
- Ramp intent vs delivery: `frames.timestamps` against `capture_log.json`.
- EXIF presence: `PIL.Image.getexif()` on any `frame-*.jpg`.

**Verify a fix on the device.** Both pipelines must be shot, because the whole
point is that they now diverge:

- JPEG arm — WB must track the illuminant, and the output must carry EXIF.
- DNG arm — must be **unchanged**. Diff its `capture_log.json` and its EXIF IFD
  against a pre-change run of the same settings.

The rig is `/letslapse` (`.claude/skills/letslapse/SKILL.md`); `ipad-m1` is in
`devices.json`. A dawn or dusk window is required — the fault only appears across
a real illuminant traverse, and a bench run under constant light will show
nothing. `tools/flicker_report.py` is the existing gate for visible luma
stepping and should be run on the JPEG arm, since Job A's option 1 risks
introducing exactly that.

**A note on the `.luma` meter:** because WB contaminates it (§3), a WB fix will
shift the exposures the ramp picks. That is expected and is not a regression.

---

## 9. Confidence

| Claim | Status |
|---|---|
| WB is locked run-long by `applyHolyGrailExposure`, not restored until run end | **Proven** — code path + no restore + pixel evidence |
| Red is destroyed beyond recovery in the JPEG output | **Proven** — p99 = 14/255 |
| The 05:48 step is streetlights, not the lock | **Proven** — region-graded, not global |
| The ramp did not run away (0.12 stops over 2 h) | **Proven** — app-metric measurement |
| Darkness is the seed anchor at −2.44 stops, by design | **Proven** — defaults + measurement |
| WB inflation costs a further ~0.4 stops | **Estimated** — from blue's 3.5% → 31% luma share |
| JPEG EXIF is never authored (not stripped) | **Proven** — call site + delivered files |

# Capture Flat on the blended JPEG path: dead where it is offered, and unlogged

**Raised:** 2026-08-23 · **Jobs A + B implemented 2026-08-23 (device verification pending)** · Evidence: A/B shoot pair `JPEG flat` / `JPEG non flat`

> **Status update (2026-08-23).** Jobs A and B are implemented on `ios-app`,
> together with the WB brief's Jobs A and B — see §8 for what each now does
> and [jpeg-holygrail-wb-brief.md](jpeg-holygrail-wb-brief.md) for the WB
> half. Job C (the sensor-side probe) is untouched. Device verification per
> §9 is still owed; nothing below has been re-verified on hardware since the
> change. One finding in §5 is corrected: the `algorithm: zone` stamp turned
> out to be truthful — Zone genuinely is the only strategy wired into this
> path (`zoneBlend` in `LiveBlendController`); the Settings strategy picker
> only reaches the DNG pipeline. That is a product gap, not a logging lie.
>
> **Addendum (same day):** the viewfinder now wears the flat look while the
> setting will actually grade the delivered file — the saturation/contrast
> half of the grade as SwiftUI compositor modifiers on `CameraPreview`
> (`previewShowsFlat`, `CaptureView`). Zero capture-side cost: nothing
> touches the session, the tap, or the meter. Video keeps its native flat
> preview when Apple Log engages (the modifiers would double-apply, so they
> gate on `!appleLogAvailableForSelection` there); scanner JPEGs are graded
> by `writeCapturedPhoto` today, so Scan mode's preview honestly flattens
> too — whether scanner captures *should* take the grade at all is an open
> product question this work did not touch.

Self-contained; assumes no knowledge of the conversation that produced it. Read
**Constraints** (§7) before writing code — this job sits directly on top of the
capture hot path and next to the Dynamic ramp's meter.

**The operator's intent, verbatim in spirit:** Capture Flat exists to dial back
contrast and saturation *at capture* so post-production keeps its full range —
highlights, shadows, contrast, grading scope. It must not be a post-capture
filter; the point is to preserve capability, not crush it. Scope is JPEG —
lossy, 8-bit, decisions baked at encode. DNG needs none of this.

---

## 1. The A/B that produced this

Two back-to-back shoots, same iPhone 16 Pro (`iPhone17,1`), same framing, same
settings, ~70 s apart, morning of 2026-08-23:

| | `JPEG non flat` | `JPEG flat` |
|---|---|---|
| Project (this Mac) | `B9E17C99-0402-4C4A-BD76-1EE6CD754637` | `27A53544-9816-463F-9ABA-DBD5BB51FDDC` |
| Capture Flat | **off** | **on** |
| Window (UTC) | 05:59:59 → 06:01:40 | 06:02:49 → 06:04:30 |
| Mode | Interval · JPEG · Psycho blend (`blendMode: unthrottled`), Dynamic, 1 s, 100 frames, 4032×3024 | same |
| blendCount | 25 per output frame | same |

Frames + `capture_log.json` under
`~/Library/Application Support/LetsLapse/Projects/<id>/source/`. Exposure held
essentially constant across both runs (ISO 104–109, 1/765–1/868 s), so the pair
is a clean pixel-level A/B.

**Measured (analysis venv, 20 frames sampled per run, luma + HSV):**

| | non flat | flat | if the grade had run |
|---|---|---|---|
| luma mean | 0.4581 | 0.4597 | — |
| luma std (contrast) | 0.1876 | 0.1904 | ≈ 0.17 (×0.90) |
| saturation mean | 0.3173 | 0.3197 | ≈ 0.25 (×0.80) |
| luma p1 / p99 | 0.068 / 0.886 | 0.068 / 0.893 | lifted / pulled |

Every delta is inside frame-to-frame noise — the "flat" run is even marginally
*more* contrasty and saturated (later sun). **The toggle changed nothing.**

---

## 2. What Capture Flat actually is today

One toggle (`FlatCapture.storageKey`, offered by `FormatSheet` —
`App/CaptureView.swift:4776`), four behaviours:

| Path | Mechanism | Where |
|---|---|---|
| Video, Log-capable **format** | Apple Log at the sensor | `CaptureView.swift:1138` → `appleLogEnabled` |
| Video, no Log at this format | save-time Core Image re-encode of the movie | `VideoFlatten.flattenInPlace`, `CameraController.swift:7381` |
| Stills via the **photo output** (Photo mode; interval shoots that fire the photo output) | save-time Core Image grade of the encoded JPEG | `FlatCapture.write`, called from `writeCapturedPhoto` (`CameraController.swift:7445`) |
| Stills via **live blend** — every blended interval shoot: numeric depth, Auto, **Psycho**, Safe | **nothing** | — |

The stills grade (`FlatCapture.apply`, `App/PhotoPreset.swift:670`):
`highlightShadow(highlight: 0.80, shadow: 0.15)` +
`colorControls(saturation: 0.80, contrast: 0.90)`.

The toggle is shown for interval whenever output is JPEG — no blend check — and
its footer promises *"Applies a low-contrast, desaturated grade as the JPEG is
saved."* On the blended path that promise is false.

---

## 3. Finding 1 — the blended path never reads the flag

The blended JPEG writer (`App/LiveBlendController.swift:786`):

```swift
let metadata = configuration.gpsMetadata?().map {
    [kCGImagePropertyGPSDictionary: $0 as Any]
}
try ImageExporter.write(image, to: url, format: .jpeg, metadata: metadata)
```

No `FlatCapture` reference exists anywhere in `LiveBlendController` or
`LiveBlendRawController`. The only still-photo caller of `FlatCapture.write` is
`writeCapturedPhoto` — the `AVCapturePhotoOutput` delegate path. A Psycho /
Auto / Safe / depth-N interval run builds its frames from the video tap through
`PixelBufferBlender` and never goes near it.

This explains the A/B exactly: both runs were the same pipeline with the same
settings; the flag was read by nobody.

---

## 4. Finding 2 — where it does run, it is the post filter the operator rejected

`FlatCapture.write` **decodes the ISP's finished 8-bit JPEG, grades it, and
re-encodes at quality 0.95**. Two lossy encodes; every tone decision already
baked by the ISP before the grade sees a pixel. Information-theoretically it
cannot add latitude — it can only redistribute the 256 code values it was
handed, and the flat curve *compresses* them into a narrower band, so the
delivered file has **less** tonal resolution than the untouched JPEG plus a
second generation of JPEG artefacts. It produces the *look* of flat capture
while destroying a little of what flat capture exists to preserve.

So even on the paths where the toggle works, it does the opposite of the
stated intent. This is the thing to fix, not just the dead path.

---

## 5. Finding 3 — no still shoot records the setting anywhere

`capture_log.json`'s session header (`CaptureExposureLog.Session`,
`Kit/Sources/LetsLapseKit/CaptureExposureLog.swift:191`) has no `captureFlat`
field. Adjacent honesty gaps found while looking, all at the Session
construction site (`LiveBlendController.swift:912`):

- `captureMode` is the **hardcoded string `"interval"`** — a Dynamic (holy
  grail) run is indistinguishable from a plain interval run in the travelling
  log.
- `algorithm` is stamped `BlendStrategyID.zone.rawValue` for every
  `BLEND=Auto` run. **Correction (2026-08-23): that stamp is truthful** —
  Zone is genuinely the only strategy this path runs (`zoneBlend` is
  hardcoded in `LiveBlendController`; the Settings strategy picker only
  reaches the DNG pipeline). Recorded as a product observation: selecting
  Latitude/Lumen does nothing on JPEG Auto runs.
- The A/B pair above cannot be told apart by any file the projects carry —
  which is precisely how this investigation had to start from pixel statistics.

Video is ahead of stills here: `LiveCaptureSequence.captureFlat` +
`.appleLog` are stamped at first-frame time (`CameraController.swift:7344`),
recording both the request *and* whether Log actually engaged. Stills record
neither.

---

## 6. The lever that already exists — spend the JPEG's 256 codes in flat space

`FrameAccumulator` accumulates the window's frames into a **float32** mean on
the GPU (`Kit/Sources/LetsLapseKit/FrameAccumulator.swift:4`) and already
exposes the right primitive:

> `finalizeMean` — *"Like `finalize`, but into a float destination that keeps
> the mean at full precision — the input to `BlendCore.encodeGamma`, which owns
> the one quantization step."* (`FrameAccumulator.swift:87`)

The blended JPEG path today takes the plain 8-bit `finalize`
(`PixelBufferBlender.swift:90`). A Psycho window averages ~25 tap frames, and
temporal noise makes that float mean genuinely deeper than 8 bits in the
shadows. **Applying the flat tone/sat mapping to the float mean and quantising
once, in flat space,** is capture-side in the sense that matters: no decision
is made on 8-bit data, and the JPEG's code values are allocated to the flat
curve instead of being re-derived from a finished sRGB encode. Fused into the
finalize kernel it costs no extra pass on the hot path.

Sensor/ISP-side levers, recorded for completeness:

- **Apple Log at the tap** — per-format; the capability matrix already answers
  **no at 4032×3024** (`CaptureView.swift:934`). Where available it changes the
  buffers the meter and strategies read — see C2. The tap is also configured
  `kCVPixelFormatType_32BGRA` (8-bit) at all four sites today.
- **`isGlobalToneMappingEnabled` / video HDR flags** — real ISP knobs on the
  video pipeline; their effect on tap flatness on this hardware is unmeasured.
  A probe job, not an assumption.

---

## 7. Constraints

### C1. JPEG only. DNG is untouched (the toggle is already hidden for DNG by design).

### C2. The tap feeds the Dynamic meter — do not change what the meter reads.

The `.luma` metering route (`meanLinearLuma`, `LiveBlendController.swift:566`)
assumes ~2.2-gamma tap buffers, and the Auto strategies read AE off the same
stream. Changing tap *encoding* (Log, HLG, tone-mapping knobs) shifts metering
— the same fragility documented as Finding 3 of
[jpeg-holygrail-wb-brief.md](jpeg-holygrail-wb-brief.md). **Flat-at-finalize
touches nothing the meter reads and is metering-neutral.** Any ISP-side change
must be measured against the ramp before it ships.

### C3. Do not regress the paths where Flat works today

(photo-output stills, video Log, video software flatten). If the photo-output
still path migrates to a better mechanism, that is a deliberate change, not a
side effect.

### C4. The WB job is upstream in value.

No flatness can recover a channel that locked white balance has quantised to 14
of 255 code values (see the WB brief). For Dynamic JPEG shoots across changing
light, fix order matters: WB first, then flat.

---

## 8. Suggested shape of the work

### Job A — truth in the log (small, independent) — **IMPLEMENTED 2026-08-23**

`CaptureExposureLog.Session` gained `captureFlat: Bool?` — stamped true/false
by the JPEG blend controller (snapshotted into its `Configuration` at run
start), left absent by the DNG controller (the setting is never offered
there). `captureMode` is now honest on both controllers: `"dynamic"` when the
run was ramped, derived from `rampExposure != nil` (only ramped runs are
handed a commanded exposure). `algorithm` was already truthful (see §5's
correction). Optional fields decode in both directions, so old logs stay
readable and old parsers ignore the new key.

### Job B — flat that is real on the blended path — **IMPLEMENTED 2026-08-23**

`PixelBufferBlender.finalizeFloatImage()` (new, in the Kit) returns the
window's mean as a half-float image via the existing `finalizeMeanLinear`
kernel — tagged linear sRGB, no quantisation. When Capture Flat is on, the
JPEG blend controller grades that mean through `FlatCapture.flatten` (the
same CoreImage filters as the photo-output path, so both paths keep one look)
and the single 8-bit quantisation happens at the render, in flat space. A
CoreImage failure falls back to encoding the ungraded mean — a frame is never
lost to the grade. Covered by `PixelBufferBlenderTests` (sub-bit precision
and linear tagging, verified against GPU output).

Alongside it, the write site now authors **EXIF + TIFF** on every blended
JPEG (the WB brief's Job B): ISO, exposure time, f-number,
DateTimeOriginal/Subsec/OffsetTime from the window-open exposure record, and
the device identity. GPS rides along as before.

Deliberately NOT changed: the FormatSheet footer (its stills sentence —
"applies a low-contrast, desaturated grade as the JPEG is saved" — is now
simply true on this path too, so no copy change and no design-sync was
needed), and the photo-output still path, which keeps its save-time re-grade
(migrating it to a pre-quantise grade is a separate decision, per C3).

### Job C — probe: sensor-side flatness (record only, then decide)

On-device: 4:3 video formats' Log/10-bit support on 16 Pro (extend
`LL_PROBE_FORMATS`), effect of `isGlobalToneMappingEnabled` / HDR flags on tap
output *and on the meter*. Only after C2's coupling is measured does
sensor-side flat become a candidate.

---

## 9. How to verify

- **Re-run the exact A/B** (same settings as §1, back-to-back). Expect:
  saturation mean ≈ ×0.80, luma std ≈ ×0.90 on the flat run, and
  `captureFlat` present in both `capture_log.json` headers.
- **Latitude, not just look:** apply one aggressive fixed test grade (e.g. a
  +2-stop shadow push) to both runs' frames and count distinct code values /
  posterisation in the lifted shadows. The flat capture must measurably win;
  if it does not, the curve isn't earning its JPEG.
- `tools/flicker_report.py` on a Dynamic run with flat on — the finalize
  change must not introduce luma stepping.
- Photo-output stills and video paths byte-identical unless deliberately
  migrated (C3).

---

## 10. Confidence

| Claim | Status |
|---|---|
| Blended JPEG path never applies Capture Flat | **Proven** — writer + no references + A/B stats identical |
| The A/B pair shows no flat effect | **Proven** — measured, table §1 |
| Stills record the setting nowhere; `captureMode` hardcoded; `algorithm` hardcoded for Auto | **Proven** — schema + construction site |
| Save-time JPEG grade cannot add latitude and double-encodes | **Proven** — code path; information argument |
| Float mean is materially deeper than 8-bit in shadows at blend ~25 | **Expected** — measure during Job B |
| Log unavailable at 4032×3024 on 16 Pro | **Recorded** from the capability matrix comment — re-verify with the Job C probe |
| ISP knob effects on tap flatness | **Unmeasured** — Job C |

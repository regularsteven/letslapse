# LetsLapse — open jobs

The queue of work that has been scoped but not done. One entry per job: what it
is, why it matters, and where the detail lives. A job leaves this list when it
ships, not when it is started.

Long jobs get their own document and are referenced from here. Short ones can
live inline.

---

## Open

### Data model — split `library.json`, stable origin ids, append-only experiment log

**Detail:** [data-model-audit-2026-09-06.md](data-model-audit-2026-09-06.md) ·
**Raised:** 2026-09-06 (Steven, audit brief) · **AUDIT DONE 2026-09-06, no
implementation** · phases 1–4 in the report's §7 · medium (phase 1) to large
(phases 2–4)

The audit inventoried every persisted store (about 35 file kinds, 83 defaults
keys, no keychain or database) against the code and both real libraries (the
Mac volume and the iPhone container). The recommendation is to keep JSON and
fix five things: per-project `project.json` with `library.json` reduced to an
index (it is 2.3 MB today, 92 % frame-name strings, rewritten on every grade
tick); `originID` / `originDeviceID` / `derivedFromOriginID` so a project keeps
one identity across devices (today every import re-mints, one hop only); the
live-blend experiment log to NDJSON (it is a full rewrite after every output,
14–19 GB of writes on a 5,000-frame shoot); a launch-time folder ↔ index
reconciliation (three orphan folders and one empty-folder record exist now,
and an undecodable manifest is overwritten by the next save); and one
serialised manifest writer with persist-before-delete ordering. Migration is
additive first, dual-write second, index third, each phase verified by a
`lapse audit` tool that diffs a rebuilt index against the real one.

### DNG archive conversion — raw → lossy / resized DNG, in-app one day

**Detail:** [dng-archive-spike-brief.md](dng-archive-spike-brief.md) (the
brief) · [dng-archive-spike/README.md](dng-archive-spike/README.md) (the
report, with `matrix.csv` / `matrix.md`) · `tools/dng-spike` (the CLI) ·
**Raised:** 2026-09-05 (Steven) · **SPIKE DONE 2026-09-05** · next step
**medium** (fold into the app), large only if third-party raws on iOS matter

Long-term: convert third-party camera raws (ARW, CR2, …) and LetsLapse's own
captured DNGs to smaller DNGs — lossy JPEG XL and resize to N megapixels, the
way Adobe DNG Converter does — inside LetsLapse on iPhone, iPad and Mac, fast
enough that storage stops being the bottleneck on long shoots.

**What the spike found (2026-09-05, M4 Max + iPhone 16 Pro probe):** there is
no JPEG XL *encoder* in any Apple framework — not ImageIO, not VideoToolbox,
not on iOS 26.6 on an A18 Pro — so libjxl (BSD-3) is the encoder. With it,
the chosen direction (report §6.1) is **camera-native LinearRaw JPEG XL**:
Kit parse (or LibRaw) → Metal demosaic → Lanczos → gamma table / cubic →
libjxl d0.5–1.0 e5 in 512-px tiles → the new `DNGArchive` writer.
1.28 MB per 8 MP frame at d0.5 (49 dB against lossless, 0.4% from Apple's
render of the source, Adobe re-decodes within 0.3%), 0.46 s per frame and
6 fps with three in flight on the Mac (486 frames in 81 s) — Adobe's size
at Adobe's quality, reading correctly in Apple's decoder *directly*.
Lossless JPEG XL on the Bayer plane is a free 9% over the Kit's lossless
JPEG (15.6 vs 17.1 MB, 90 ms). Lossy on the mosaic drifts at night. The
8-bit JPEG route (no third-party code) is the proxy tier, not the archive.
Apple's decoder rules that decide the container shape are in the report's
§4 (per-sample levels on LinearRaw; table vs polynomial depends on the
codec; no whole-frame tiles; one crashing tile layout).

**Folded into the app (2026-09-05 evening):** the pipeline moved into the
Kit (`Kit/Sources/LetsLapseKit/Archive/`, `DNGArchive.Converter` /
`Strategy`, tests in `DNGArchiveConverterTests`), libjxl + LibRaw travel as
one static `CLetsLapseCodecs.xcframework` binary target (`Kit/Binaries/`,
19 MB, one module map for both — Xcode cannot take two static xcframeworks
each with a root module map), and an interval project's ⋯ menu gained
**Duplicate as DNG archive…** (`App/ProjectDNGArchive.swift` sheet — size
Keep/12/10/8/6 MP, quality standard d0.5 / compact d1.0 / lossless /
lossless mosaic — and `AppModel.duplicateAsDNGArchive`, which clones the
manifest, sidecars, notes, masks, fonts and overlays, converts the frames
two in flight, writes a `dng-archive.json` ledger and registers the new
project). `LL_DNGARCHIVE=<id>|latest` (+`_MP`, `_DISTANCE`, `_LIMIT`,
`_INFLIGHT`) runs it headless and prints per-frame timings. **iPhone 16 Pro
measured:** 0.50 s per 8 MP frame (libjxl 280 ms), 1.9–2.1 frames/s, 12 MP
at 1.6 frames/s — seven times faster than the 3.6 s shoot cadence. **iPad
Air M3:** 0.4 s per 8 MP frame (libjxl 185 ms), 2.5–3.2 frames/s on its own
night DNGs. **Mac clone of `E854D311` (483 ARWs → 10 MP standard):** 483
frames, 8.8 GB → 707 MB, registered as "Vltava_ARW · DNG hook", 2.8–7.5%
from Apple's ARW render (the Sony-profile gap), Apple opens every frame
directly. **Mac clone of `F6387DFA` (207 blended DNGs → 8 MP standard):**
3.6 GB → 287 MB as "nature · DNG hook", 0.4–0.7% from Apple's render of
the source, blocks within 8% (the demosaic difference at 8 MP). Design
SVGs for the sheet and the menu row are OWED after the Mac sign-off
(app-code-first by Steven's instruction).

**Validated against Adobe (2026-09-05 late, report §8):** the first in-app
clone of an iPhone 16 Pro project (105 frames in the unregistered folder
`5968F261-…`) was refused by Lightroom — the writer carried the single-IFD
Apple original's CFA and 4224-wide crop tags into a 4032-wide LinearRaw.
Fixed and fenced: raw-owned tags filtered, ActiveArea crop, 2-component
tiles, the OpcodeList3 GainMap baked (Metal) or carried, and
`DNGArchive.validate` on every write (`dngspike validate --adobe` for the
Adobe verdict). Measured with Adobe DNG Converter as the yardstick, in
camera space: the lossless mosaic is bit-exact, the demosaiced archive
within 1% of Adobe's own linear conversion, and the lossy carrier moved
from a gamma table over a 2048 pedestal (−4.6 counts of bias in the noise
below black) to a slope-matched toe table over a 12288 pedestal
(`Curve.toeLUT`, +0.0), now at or better than Adobe's own lossy JPEG XL.

**Still open:** Steven's own Mac / iPad pass over the sheet and the SVG
mirrors; Lightroom itself (Adobe DNG Converter accepts every shape now, the
application was not driven); the in-app viewer renders a lossy archive of a
*noisy night* frame ~8% differently from its uncompressed twin through
Apple's raw pipeline (noise texture; Adobe's decode does not) — decoding
our own JPEG XL for the viewer would remove that; deleting the orphan
`5968F261-…` folder (~300 MB of invalid frames, not in the library);
Float16/UInt16 intermediates for the iPhone memory budget (Float32 today);
the BaselineExposure source for third-party raws
(`DNGArchive.Strategy.knownBaselineExposures` holds the ILCE-7M4's 0.35 for
now); a "Delete originals" companion once an archive has been checked; the
iPhone 12 Pro / iPad Air 5 probes (`LL_DNGPROBE=1`); a flicker report over a
converted sequence.

### Settings ▸ Display: blackout, reduce brightness, and the scheduled peek

**Detail:** `docs/design/iOS/settings.display.portrait.svg`,
`capture-interval.running.blackout.portrait.svg`,
`capture-interval.running.peek.portrait.svg` ·
**Raised:** 2026-09-05 (Steven) · **SHIPPED 2026-09-05 (design first, then code, signed off between) — device sign-off owed** · medium

Design-first pass, signed off on the SVGs before any Swift. The problem
Steven put: a blacked-out shoot gives no sign it is going well, and the only
way to look is to touch a phone that is on a tripod — which is how a run gets
knocked out of frame.

**Settings.** "Dim screen during shoot" leaves ADVANCED for a new top-level
**DISPLAY** section between RECORDING and LOCATION, renamed **Blackout
viewfinder** — the row floors `UIScreen.brightness` *and* covers the
viewfinder, so "dim" was never what it did. Two levers, split because they are
opposite on the two panel types: on the OLED iPhones almost all the saving is
the **cover** (black pixels are off, so the slider is nearly free once the
panel is covered), and on the LCD iPads it is the **brightness**, because the
backlight burns whatever is drawn. New **Reduce brightness** (OFF) is that
second lever, and it is also the level a lifted curtain returns *to* — which
is why the two are independent rows rather than one three-way picker. Then
**Scheduled peek** (ON) / **Trigger** (Interval | Clock, default Clock, a
Clock peek inside the first 60 s of a run suppressed) / **Every** (5m default,
10m, 15m), shown only while the blackout is on.

**The peek shows a status card, not the viewfinder.** A restored preview
answers "is it going well?" badly at three metres, and costs the OLED exactly
what the blackout was turned on to save. The card is legible across a room and
~94 % black: latest frame + its age, frame count as hero, a cadence verdict
(On schedule / Falling behind), ELAPSED · THERMAL · SPACE chips, `runExposureLine`
verbatim, the short blend readout, and a footer saying when the screen goes
back and when the next peek is — a screen that blacks itself unannounced reads
as a crash. No controls on it: a tap anywhere is the existing
`ShootScreenDimmer.wake` (30 s of real screen), which is the only route to stop.

**Two fixes to the blackout itself, in the same unit of work.** (1) The
brightness floor comes off absolute zero to **0.05** — `UIScreen.brightness`
caps every pixel on the panel, so at 0 the alive-signal cannot be seen, and on
OLED the difference between 0.05 and 0 with a black cover up is noise.
(2) The heartbeat becomes a 6pt `LL.amber` dot resting at 0.12 and **pulsing
per captured frame**, replacing the 5pt red-at-30 % dot that is invisible in
the field. It says more than the system indicator can: green means the camera
is powered, a pulse means LetsLapse took a picture.

**Steven's green-light question, answered and recorded in the blackout
mirror's `desc`:** the app cannot brighten the system camera indicator.
`UIScreen.brightness` is a panel-wide hardware write with no per-element
exemption, so at the floor the dot is dimmed, not off. It reads clearly on
Dynamic Island phones (the dot sits on the island's black surround at maximum
contrast) and poorly on the 12 Pro's notch — the difference he saw between the
two devices. `CaptureView`'s `.statusBarHidden()` is not the cause: it applies
whether or not the blackout is engaged, and the dot is visible undimmed. The
app's answer is the heartbeat, not the system's dot. **Worth one dark-room
confirmation on both phones before the code lands.**

*Shipped: `ShootPeekSchedule` in the Kit (`interval` / `clock`, the 60 s
opening grace, 14 tests — 578 Kit tests green); `ShootDisplayPlan` +
`ShootPeekCard` beside a rewritten `ShootScreenDimmer` (one `apply(_:)` entry
point rather than four setters that can disagree; `runBeganAt` because
`captureRunStartedAt` is written on the session queue and is not published, so
the first plan of a run can arrive with it nil); `displayCard` +
`peekTriggerRow` in Settings; `CameraController.latestFrame`, published from
the stills write path and mirrored off the blend snapshot's new
`lastOutputURL`; `DurationFormatter.compactAge`; `LL_PEEK=card`. Four defaults
keys are new and `ShootScreenDimmer.defaultsKey` is NOT — nor are
`setDimDuringShoot`, the `dimDuringShoot` state-frame key or `shoot.py --dim`,
so no bench script breaks; only the Watch row's label moved (Dim Screen →
Blackout). Verified on the iPhone 16 simulator (393 pt) and both mirrors
re-measured against it.*

**Three SwiftUI traps the mirror only caught once the app drew it**, all worth
remembering: a settings `Toggle` needs `.labelsHidden()` or it claims half the
row and squeezes the subtitle column to ~117 pt against its neighbours' 207 pt
(every other row in `SettingsView` has it); every settings toggle here carries
`.tint(.green)`; and a SwiftUI `Menu` label renders in `LL.accent` whatever
`menuValueLabel` asks for, which also makes `settings.advanced.portrait.svg`
stale for its two field-test values (noted in the INDEX, not fixed).

**Owed:** device sign-off, and specifically the dark-room check of the green
indicator on both phones — the reasoning above is sound but unverified. Then
the peek's alert form (🟡 in the iOS INDEX), the collapsed Display card (🟡),
and three mirrors this pass found stale and deliberately did not fix:
`settings.portrait.svg` (missing the ON-DEVICE AI section entirely, and it now
needs DISPLAY too) and both watchOS controls mirrors (the Dim toggle has never
been drawn, and now carries the renamed label).

### Lossy DNG stage 2 — a camera-space decode that renders like Lightroom

**Raised:** 2026-09-05 (Steven — archival Sony ARW → Adobe DNG Converter
lossy JPEG XL at 10 MP, projects `E854D311` ARW / `93F772E0` lossless DNG /
`8E67730E` lossy full / `B91FD599` lossy 10 MP) · open · **medium**

Stage 1 shipped the same day: `LossyLinearDNG` (Kit, `Grading/`) repacks an
Adobe lossy DNG in memory — ImageIO decodes the JPEG XL tiles, the Kit runs
the DNG stage-2 arithmetic (per-plane black, white, `MapPolynomial`) itself
keeping sub-black noise negative, re-quantises onto a uniform 2048 pedestal
and hands an uncompressed LinearRaw DNG to `CIRAWFilter(imageData:)`. That
routes around Apple's decoder, which mishandles `BlackLevel` whenever
`MapPolynomial` opcodes are present (green wash; measured identical on macOS
15.6, iOS 18.6 and iOS 26.1 simulators). Every raw decode — editor, blend,
thumbnails, framing measurement, `lapse` — opens its converter through
`LossyLinearDNG.rawFilter(for:)`. `LossyLinearDNGTests` holds the lossy
containers to the ARW gold standard within a few points of what the lossless
DNG achieves.

Stage 1 renders a lossy frame the way Apple renders the lossless conversion
of it, which is what the app shows for every other DNG. It does not render
the way *Lightroom* does: Apple's profile handling, not Adobe's, and the
embedded Adobe Standard hue/sat map and look table go unused. The files are
already demosaiced and carry ForwardMatrix1/2, so a genuine camera-space
decode needs no demosaicer: tiles → stage 2 (as stage 1 does) → AsShotNeutral
white balance → ForwardMatrix (`ForwardMatrixDecoder` already interpolates
by illuminant) → XYZ D50 → linear P3, with the embedded profile tables
applied through `DCPProfileApplier.Tables.lookAndHueSat` — the "genuine
camera-space decode" the DCP path was scaffolded for. Also on iOS, where no
Adobe profile directory exists, because the tables are in the file.

Open questions for that job: where dng_sdk clips the noise floor (stage 1
keeps negatives through to Apple's matrix, which matches the ARW; Lightroom
may clip earlier), whether the legacy 8-bit lossy JPEG flavour (compression
34892) decodes right through stage 1 — it is accepted but only JPEG XL was
verified — and a Settings-level way to see which decode a frame took.
Related memory: `adobe-lossy-dng-apple-decoder-bug`.

### Ramp readout runaway on a non-driving ramp — measurement, readout honesty, Ladder EV, logging

**Detail:** [fieldtests/2026-09-04-ladder-readout-runaway.md](fieldtests/2026-09-04-ladder-readout-runaway.md) ·
**Raised:** 2026-09-05 (Steven — 12 Pro Ladder dusk shoot 2026-09-04, project
`8BC64DBE`) · open · **high** (a false alarm stopped a good shoot; the Ladder
re-paced the clip on a phantom EV)

The ramp never drove the 12 Pro's virtual camera (`ramp commanded nothing`
at window 0, refusal reason console-only), the run shot on AE — and the
engine then chased itself: the JPEG path measures
`EV(commanded pair) + log2(luma/0.18)`, which is scene-referred only while
the camera obeys, so every phantom step was read back as the scene moving.
Target 1/305 → 1/71429 s, "scene EV" 11.6 → 19.6, while the frames went
1/296 → 1/121 and EV 11.2 → 8.8. The amber line printed the target, the red
"past the sensor's limit" fired on it, and the Ladder stepped Fading →
Daylight at 17:37:53 (pacing 2 s × 5 → 3 s × 10, in the finished clip). All
three Ladder runs that evening ran on AE; the second project (`0F387359`)
walked the other way (1/45 → 1/26 while AE went 1/121 → 1/50) and opened on
Dusk then stepped to Fading at window 1 from two disagreeing EV scales. Dim
only hid it. Side finding:
`sceneExposureValue()` adds `log2(ISO/100)` where EV100 subtracts it (3.2
stops low at ISO 33, 10 stops high at ISO 3200) — the Ladder's arming EV and
the idle light panel read it, and the Scanner torch threshold is tuned to it.

*Shipped 2026-09-05 (uncommitted, Kit tests green, iOS build green):*
**(1)** the luma measurement reads through the DELIVERED pair — each
video-tap frame's own EXIF off the sample buffer (`BlendWindowScene`), never
the engine's target — with five regression tests including the runaway
itself; **(2)** `HolyGrailState.isDriving` + delivered pair + reason: the
amber line prints `1/121 · ISO 71 · EV 8.8 · ramp not driving`, never red,
the reason behind the Info toggle; mirror
`capture-interval.holygrail-running.refused.portrait.svg`,
`LL_HOLYGRAIL=refused`; **(3)** the Ladder resolves on the AE's scene EV and
`sceneExposureValue()`'s sign is fixed (the torch threshold was written on
the right scale — no re-tune); **(4)** `capture_log.json` gains per-window
`ramp` records, `divergenceReference`, `rampDriving`/`rampRefusals`,
refusal/recovery/rung-change issues on both pipelines (device facts on the
refusal line), `frames.timestamps` carries the delivered pair, the
experiment log keeps its `liveblend-` name, and `Logs/console-<launch>.log`
keeps every `LLog` line; `tools/ramp_audit.py` reads it all.

Owed: **(5)** the 12 Pro run — the refusal reason now lands in `issues[]`
with the device facts, so one Ladder run and `ramp_audit.py` on its project
answers what the 2026-08-27 hypothesis could not; the simulator check of the
amber line's fit; Steven's sign-off of the mirror; and the product call on
whether a run whose ramp is refused should say so in a toast at arm time
rather than only on the readout.

### Encode quality — ProRes master, constant-quality mode, and the encode-path secondaries

**Raised:** 2026-09-04 (Steven — Lightroom → Resolve vs LetsLapse comparison on
`E33ED216` / `76BEF654`) · open · medium · policy:
`Kit/Sources/LetsLapseKit/VideoEncodePolicy.swift` · tests:
`VideoEncodePolicyTests`

*Shipped 2026-09-04: the bitrate budget is per pixel per FRAME again — the
`min(fps, 30)` in the rate term had halved what every 50/60 fps frame got
(4032×3024 @ 60 measured 0.12 / 0.09 bits per pixel; an encoder-only test on a
clean reference kept 36 % (H.264 88 Mbps) / 21 % (HEVC 10-bit 66 Mbps) of the
finest-band detail, 56 % at 250 Mbps, 100 % for ProRes). Ceilings are now
200 / 160 Mbps.*

Still open, in order:

1. **ProRes 422 HQ master output for blends.** `OutputCodec.prores` exists in
   the Kit and the CLI (`VideoBlender.swift`), but the app offers only
   H.264 / 10-bit HEVC. A grade-elsewhere workflow (Resolve) wants a master;
   48 MP sources cannot be H.264 or HEVC at all (Level 6.2 caps at 8192×4320).
   `.mov` file type, `blends/<uuid>.mp4` naming, thumbnails and share paths
   all assume MP4 today.
2. **Constant-quality encode mode.** `kVTCompressionPropertyKey_Quality` is
   honoured only by some encoders and an unsupported key raises at
   `AVAssetWriterInput.init` — probe with `VTCopySupportedPropertyDictionary`
   first, then expose Standard / High / Maximum.
3. **Secondaries found in the audit:** `VideoBlender.swift` (~:338-343, :476)
   and `TimeSliceRenderer.swift` (~:281-286, :395) feed a `32BGRA` pool into
   a Main10 writer and tag 709 primaries on a P3 stream (8-bit pixels inside
   the "10-bit" path); `MacVideoJobRunner.swift` (~:696) hardcodes
   `.h264High8Bit` and ignores the user's HEVC choice; `CollectionExporter.swift`
   (~:91) still uses `AVAssetExportPresetHighestQuality`, which chooses its
   own bitrate, writes no colour tags and can bin frames.

### Graded still export — full-chroma JPEG or a lossless format choice

**Raised:** 2026-09-04 (Steven) · open · small–medium · writer:
`PhotoGrader.renderJPEG` (`App/PhotoPreset.swift`), `LinearFrameDecoder.cgImage`

A graded copy of a Lightroom JPEG (4:4:4, q≈95, 5.9 MB) leaves the app as
4:2:0 at quality 0.95 (5.1 MB): luma detail is fully kept, chroma resolution
halves (spectral power at 0.5–1.0 Nyquist keeps 13–26 %). ImageIO writes
4:4:4 only at quality 1.0, which is ~2.5× the size (11.6 MB) — Steven ruled
that out. Shipped 2026-09-04: the copy is tagged in the source's space (sRGB
for a display-referred source, Display P3 for raw). Owed: a 4:4:4 writer at
Lightroom's size (a non-ImageIO JPEG encoder), or an Export… format choice
(JPEG max / 16-bit PNG / TIFF) with its design SVGs.

### DNG neutral look — re-fit against Apple's render across the clip, and raw capture sharpening

**Raised:** 2026-09-04 (Steven — the Lightroom comparison) · open · medium ·
engine: `ToneMath.baseCurvePoints`, `LinearFrameDecoder` (`boostAmount 0`,
`extendedDynamicRangeAmount 2`)

The hidden base look was quantile-mapped from ONE calibration frame onto
ImageIO's default render of that DNG. Across `E33ED216` the untouched render
sits flat next to Lightroom's defaults: for frame 2401, ImageIO's own render
reads p50 181 / p95 229 against the app's 165 / 196 (that export carries
Steven's grade, so the gap is an upper bound). Two candidate moves, both
changing every existing DNG project's look: re-fit the curve across frames
(or promote the look to a visible preset and make neutral honest), and add a
Lightroom-style default capture sharpening for raw (amount 40 / radius 1 /
masking 25 has no counterpart — `sharpen` defaults to 0, and Apple's boost,
which carries its own sharpening, is off). Give the `lapse grade` rig a
stored expectation first so the re-fit is measurable.

### Framing lock — resample quality of the per-frame lock

**Raised:** 2026-09-04 (Steven; measured on `E33ED216`) · open · small ·
engine: `FrameRotation.levelled` · doc: [framing-lock.md](framing-lock.md)
("sub-pixel resample vs integer copy")

`levelled`'s bypass keys on `rotating || shifting || insetting`, and the
inset is a whole-shoot constant — so with a lock committed EVERY frame,
the reference frame included, takes a bilinear sub-pixel translate followed
by a ~0.7 % `CILanczosScaleTransform` upscale: a full-frame low-pass with no
magnification benefit. Measured drift inside one 8-still window is 1.2 px
(frames 2401 → 2408), so an unlocked blend smears by about a pixel anyway;
the question is how to lock without softening. Options: integer-pixel blit
(≤ 0.5 px residual, no resample, size unchanged) or one Lanczos pass that
translates and crops without scaling back (output at the cropped size,
~4004×2994 for a 0.7 % crop — needs design sign-off). Steven 2026-09-04:
follow-up, not part of the output-quality fix. A/B today: Adjust › Advanced ›
Apply stabilisation.

### Display-referred neutral — the accepted behaviour change

**Raised:** 2026-09-04 · **shipped 2026-09-04** (engine version 6) · note only

Every JPEG/HEIF/PNG project — imported and captured (Mac interval is always
JPEG, iOS JPEG mode) — now renders "Original" as its own pixels on every
surface; before, the engine's DNG base look lifted them (median gray 198 →
228 on a Lightroom export, blue clipped). Grades and presets saved on such
projects were authored against the lifted look and now sit on identity —
darker and flatter than the day they were made. Not migrated: there is no
correct slider translation of "lift by the base curve", and the old look was
a bug on these sources. DNG projects are pixel-identical (guarded by
`GradeEngineTests` and `DisplayReferredNeutralTests`).

### Framing lock — post-capture stabilisation of interval shoots

**Raised:** 2026-09-03 · **Engine, design files and app wiring shipped
2026-09-03 (uncommitted) — Steven testing on the Mac; screenshot
verification against the SVGs, the viewer/preview/motion-player lock and
an iOS timing check owed** · medium · design + engine notes:
[framing-lock.md](framing-lock.md) · tools: `lapse framing`, `lapse stack
--lock`, `tools/framing_lock_report.py`

*Decided by Steven 2026-09-03: engine first → design → UI; lock everything.
Product shape agreed: on the interval project detail's Originals card, a
**Review photos** row (progress, then a report of the knocks and the plan —
human copy and the numbers in one `source/framing.json`) and a **Stabilise
photos** row, disabled until a review exists, that commits the plan as
metadata — never a pixel on disk; in Adjust › Advanced an **Apply
stabilisation** switch, ON by default once stabilised, OFF and disabled
before. The Kit engine, the `lapse` commands and 14 tests are in; the E33
plan is committed and `lapse stack --lock` renders its 803–810 window crisp.
Owed: the SVGs, the app wiring in every stills consumer, the sidecar in the
export/import/transfer lists, an iOS timing check — itemised in the doc.*

A tripod on a bridge moves when a tram crosses. `E33ED216` (16 Pro
telephoto, DNG, 5030 frames, sunset → night) has **25** bounce events of
2–10 px — pure vertical translation, no rotation, no scale, zero issues in
the capture log, never thermal-critical — and at speed 8 every one of them
ghosts the edges inside its 8-still window and wobbles the framing between
windows. Locking the whole shoot to one reference framing costs a **0.76 %**
crop (4001×3001 of 4032×3024). Unlike the 12 Pro OIS park below, nothing at
capture can prevent this; it is post-capture by nature.

The job: a measurement pass (Vision translational registration or the Kit's
own `FrameAlignmentGate` correlation at stride 1–2, anchors chained every
~30 frames, reduced-scale raw decode) into a `frames.alignment` sidecar;
then a per-source-frame translate + fixed inset + scale-back applied through
the one decode closure of each stills path (`PhotoPreset.blendSupport`'s
`decode`, `stackSequence`'s `loadFrame`, and the poster fast path's texture
provider — same `BlendWindowRenderer`, so posters stay identical), composed
with `FrameRotation` so a levelled and locked shoot resamples once. UI: a
*Lock framing* switch in the Adjust (photos) ··· drawer with a cost line,
and a real "Measuring framing…" processing phase. Decisions owed first:
lock-everything vs bounce-only, sub-pixel vs integer, the crop cap — all
laid out in the doc with the measurements behind them.

### Light Ladder — a fourth Interval MODE (Basic · Dynamic · Scanner · Ladder)

**Raised:** 2026-09-03 (Steven — Claude Design handoff "Light Ladder
interval profile", Turn 2) · **Built 2026-09-03** (Kit model + 21 tests,
store, engine hook, capture screen, list/editor/rung, test-card ramp; two
16 Pro runs — the pressure-floor fix from the first is unproven until a run
reaches serious) · **Mirrored 2026-09-03** (the seven SVGs + the Create row,
`LL_LADDERS=list|editor|rung`, rung title inline). Owed: the §9 card bench,
one real dusk, device sign-off of the mirrors. Plan, model, decisions and the
bench: `docs/light-ladder.md`.

A shoot follows a user-authored table of **rungs** keyed on scene EV; each
rung fixes ISO, shutter, WB, interval and blend depth. The servo stays in
charge — a rung is a box of constraints handed to the Holy Grail engine, so
exposure never steps; interval and blend step at the boundary. Built-in
"Bright & Fast, Dark & Slow" (13 · 8 · 4 · darker), cloneable, never edited
in place; `light_ladders.json` beside `custom_presets.json`. Twelve
decisions taken 2026-09-03 by recommendation (Night shutter auto ≤ 1 s not
pinned; governor may lengthen a rung's interval, never shorten; WB auto =
tracked; ribbon editor; iPhone + iPad first). "Mac hidden" was taken by
recommendation too and **reversed the same evening** (Steven: never
intentional) — the Mac has Ladder **stepped by hand**: availability is per
mode, the rung's spacing and blend apply, exposure stays the camera's own,
the operator steps the rung from a RUNG dial in the row — armed, and under
the run's readout — and ladders are authored on the Mac (D13, §6.7;
`macOS/capture-interval.ladder*.svg`).
Acceptance bench = the monitor test card's brightness ramp, designed before
the engine hook. The seven SVGs and the Create-row edit are mirrored (iOS
INDEX ✅, sim screenshots); the device pass that signs them off is not, nor
is a real-camera Mac run that steps mid-run, nor the macOS SVG's sign-off.

---

### Time-slice poster fast path — what is still owed

**Raised:** 2026-09-02 (Steven) · **Implemented 2026-09-02** (Kit, CLI,
app, Adjust cost line; Mac-verified against the 1,480-frame library —
`docs/time-slicing-poster-fast-path.md` carries the numbers). Left open:

- The §7 stage-6 iPhone run at depth 1 with DNGs, for the RAW-decode-per-
  band number and the thermal picture.
- Sign-off on the four §9 decisions taken by recommendation (cost line
  only; iOS chunks of 4; the `lapse poster` CLI kept; fast posters not
  bit-identical to tail-pass posters), and on the code-first mirror
  `docs/design/iOS/adjust.timeslice-poster.portrait.svg`.
- Video sources (§8) — a second job with its own plan.

---

### Time-slice variation batches: run one in the app

**Raised:** 2026-09-01, out of the variations + grid-mode build

The whole feature is built and the engine is proven — grid geometry and
four-variation batches render end to end through `lapse slice`, and 22 new Kit
tests cover the layout, the ladders, the poster mapping and the batch
generator — but the **app-side orchestration has never actually run a batch**.
The Mac used for the build had its screen locked, which puts a Window Server
shield over everything and blocks synthetic input, and the headless routes
(`LL_ADJUST_CREATE=1`, `LL_AUTO=process`) failed to start a blend *even with
slicing switched off entirely*, so the harness — not the change — is what
stopped it.

What to check, on the Mac, against a real interval or video shoot: arm
`LL_TIMESLICE="segs:24,lag:2,vars:4,mode:mixed,seed:305419896"` inside
`LL_ADJUST` (it nests there — `openCapture` clears the recipe, so the hook does
nothing on its own), press Create, and confirm that one run registers four
sliced `BlendProject`s beside one regular clip; that each carries its own
recipe and `variation` stamp; that the grid members' summaries record the
derived row count and cell size; that the master temp is removed only after the
last variation has read it; and that the progress bar crosses the slice band
once rather than four times. Detail: `docs/time-slicing.md` §10.7.

---

### Out-of-app imports: follow-ups from the first build

**Raised:** 2026-09-01, out of the "Import a video" / "Import photos to stack" build

Both Create rows now build real projects rather than staging a blend.
`LetsLapseKit/ImportedStills.swift` reads every frame's EXIF and rebuilds the
sidecars a captured interval shoot writes for itself — `frames.timestamps`,
`frames.exposure`, `capture_log.json` — so an imported shoot lands on its own
capture clock with its own exposure trail. Files keep their names, the shoot's
own date becomes `createdAt`, and the raw gate (`ImportedStills.isRaw`) now
covers every camera family rather than the two extensions the app used to
write itself. Verified end to end on macOS against a 306-frame Sony ARW shoot
(18m26s span, 3.624s median interval, sub-second timing) and a 137 MB MP4.

Still open:

- **iOS/iPadOS verification.** Everything above was checked on the Mac only.
  Three things genuinely differ there and none has been run: the widened raw
  gate matters *most* on iOS (ImageIO hands back the embedded preview for a
  raw file — see the 2026-08-26 DNG finding, and the purple-frame-0
  signature), the Files picker over `[.image, .rawImage, .folder]` is
  UIDocumentPicker rather than NSOpenPanel, and the Photos-library path's
  `PHAssetResource.originalFilename` lookup needs a real library. Hooks:
  `LL_IMPORT_STILLS=<path>[:<path>…]`, `LL_IMPORT_VIDEO=<path>`.
- **Nothing surfaces the session log.** `capture_log.json` now travels with
  every imported shoot carrying the camera, the lens, the pixel size, the
  measured interval and per-frame ISO/shutter/aperture/EV — and the app reads
  exactly one field out of it (`captureFlat`). The same is true of shoots
  captured here. A "how this was shot" panel on the project screen would pay
  for itself twice over the moment it exists.
- **The review step, deliberately deferred** (Steven, 2026-09-01: straight
  through first). What it would add: name the project, confirm the inferred
  interval, and drop outliers *before* several gigabytes are copied. Today
  the answer to a stray frame is Bad Frames after the fact, which works
  (nomination is by `lastPathComponent`, so it is name-agnostic) but only
  after the copy.
- **Imported video is thin by comparison** — creation date, size, fps and
  codec, which is most of what an MP4 container carries. Not yet lifted: the
  QuickTime location atom (a captured video writes a `.gpx` sidecar), and any
  per-segment structure — an imported clip has no `sequence.json`, so it warps
  as one stretch. Both are only worth doing against a real source that has
  them.
- **`ImportedStills.Sequence.issues()` is written and never read.** Out-of-order
  capture times, long gaps and mixed frame sizes are recorded into the session
  log's issue trail, where the same field is already used for thermal and
  framing events. Nothing shows any of them yet.

### Text overlays: export baking for VIDEO-source blends and tail passes

**Detail:** [text-overlay-spike.md](text-overlay-spike.md) · **Raised:** 2026-08-31, out of the spike · **Narrowed:** 2026-08-31 — stills paths shipped (864c5f5)

Stills projects now bake overlays into blended clips, timelapses and long
exposures (`ImageStacker.overlayComposite` + `OverlayExportBake`), verified
end-to-end. Still open: video-source blends — the `VideoGrader`-family
composition handlers plus the `willBakeGrade` / `hasTailPass` /
`grade.isKeyframed` map gates that all assume grade-is-the-only-reason —
which only matters once `VideoEditorView` can author overlays at all; the
graded single-still export (`PhotoPreset.engineRender` full-res /
`renderJPEG`); and the Ken Burns collection export (layer-instruction path,
no CI handler).

### Text overlays: productization follow-ups from the spike

**Detail:** [text-overlay-spike.md](text-overlay-spike.md) · **Raised:** 2026-08-31 · **Narrowed:** 2026-08-31 — the Text Features build closed the multi-layer, typography, box/auto-size and custom-mask items

Closed by the "Text Features" design build: multiple layers with reorder /
visibility / onion skin, type fundamentals (family, B/I/U, alignment,
colour, kerning, line height, paragraph), Free vs Box with auto-size, the
Masks tab with project-level custom masks, and archive travel (`masks/` is
in `ProjectArchive.transferableSubfolders`; `overlays.json` was already in
`transferableFiles`).

Closed by the "Photo viewer text transitions" build (2026-09-03,
[text-reveals.md](text-reveals.md)): **font upload** (Import font… in the
picker, `fonts/` travels), **draggable range-band handles** (the lanes under
the strip), and the iOS layout pass in the simulator (stacked lanes, the
keyboard accessory bar, the typing layout).

Still owed, roughly in value order: **VideoEditorView overlay rendering**
(its Text tab is still an honest placeholder — and the reveals, exits and
sequencing above only bake through the stills path); **device pass** — the
reveal panel, the lanes' finger-sized trim handles and the accessory bar
were exercised in the iPhone 16 Pro simulator, not on a phone; promote
`overlays.json` into a `CaptureProject` field; detail-patch/loupe render
without overlays; SceneMasks **and the per-project `masks/` and `fonts/`
folders** on the storage card's clear-cache path; SegFormer-B0 ADE20K
conversion for true sky probabilities (DETR is 0/1 argmax).

Follow-ups from the reveals build itself: the **Blur** style renders each
unit through a Core Image pass (a 4000 px character-unit blur on a long
line is the slow case — measure on an export before shipping a blur-heavy
title); per-word styling needs iOS 18 / macOS 15 for the caret read-back
(`TextSelection`) — on the 17/14 floors the bar acts on the whole layer;
`LL_EDITOR` on macOS opens the editor window **two or three times** over the
same project (each hook route opens one), which the persist guard tolerates
but a screenshot run has to trim; and playback runs at the newest blended
clip's output length only once one exists (14 s tour before).

### Sky mask quality: guided-filter refinement, then a better model

**Detail:** [sky-segmentation-quality.md](sky-segmentation-quality.md) · **Raised:** 2026-08-31, out of Steven's Prague skyline · **Narrowed:** 2026-08-31 — the misleading dials are fixed

Fixed already: Threshold no longer pretends to work on an argmax grid, edge
bias is bipolar and defaults to 0, the locked-off case is the assumption
rather than a coin flip, and the vote samples 25 frames so the dial has 26
levels instead of 10.

Open, in value order:

1. ~~Guided-filter refinement~~ — **shipped 2026-09-01.** The mask boundary
   now sits 4.9 px from a real image edge instead of 12.6. `CIGuidedFilter`
   is a registered no-op; the shipped version is box blurs + two
   `CIColorKernel`s, and the CIContext needs a float working format or the
   signed coefficients clip to nothing.
2. **Keep continuous alpha.** The chain still thresholds to binary BEFORE
   the refinement sees it, then feathers afterwards — it discards the soft
   boundary and fakes one. Now the biggest remaining structural item:
   threshold last, or not at all.
3. **Revisit the threshold default.** Measured on two scenes, the optimum is
   near the BOTTOM of the range (0.05–0.15), and 0.5 visibly pulls the sky
   back off the skyline. Two scenes may now be enough to move it.
4. **A better model.** 2.46 of the 2.69 IoU points of error are the model,
   not the grid — so this is the biggest single term, and also the biggest
   job. Candidates: ADE20K scene parsers with a real `sky` class (DNL,
   ISANet, FastFCN, SegFormer-B0 at 512²; ready-made Core ML conversions
   exist in the john-rocky zoo) or a sky-specific matting network. Wants a
   bake-off against the hand-drawn reference before committing.


**Do NOT** spend effort on tiled or higher-resolution inference: the ceiling
test says a perfect mask on today's 448 grid scores 0.9977, so ≤0.23 points
are available there.

### Manual mask correction — "Add to Sky" / "Remove from Sky"

**Detail:** [sky-segmentation-quality.md](sky-segmentation-quality.md) · **Raised:** 2026-09-01, Steven's proposal after the guided-filter work

Let the photographer fix the mask by pointing at what is wrong, instead of
drawing a whole custom mask by hand. Sky is the nominated region; "Add to
Sky" grows it from where you click, "Remove from Sky" takes buildings,
ground and trees back out. The stopping rule is local: keep going while the
neighbourhood looks the same, stop at a contrast line, because a contrast
line is an object.

**Most of the engine already exists.** The guided filter shipped 2026-09-01
is an edge-aware propagator — it already takes a coarse region and snaps it
to the photograph's own edges. Pointing it at a user's scribble instead of
the model's output is a step, not a subsystem.

**Design notes, in rough order of how much they matter:**

1. **Corrections must be stored as INTENT, not as pixels.** A stroke list
   ("sky at 0.4,0.2", "not-sky along this path") re-applies against whatever
   mask the engine produces next; a baked mask dies on the next re-vote,
   grade change or model swap — and a model swap is on the roadmap. Getting
   this wrong means asking people to redo their corrections to get a better
   model. The tempting shortcut — seed a custom mask from the current Sky
   mask and let people edit that — works next week and severs the model link
   permanently. Don't.

2. **Click-to-correct before paint.** Every measured error sits within 50 px
   of the boundary, and the boundary is now snapped by the guided filter.
   What is left is the model being confidently wrong about a REGION — a dark
   roof read as sky, a bright cloud missed. That is one click, not a stroke.
   Keep a brush for what a flood cannot express (a thin railing, the gap
   between two spires), but the click is the primary gesture.

3. **Grow locally, not from the seed.** Compare each candidate pixel to its
   already-accepted neighbours, not to the original seed colour. A sunset sky
   is a gradient from gold to deep purple: a fixed tolerance from one seed
   either stops a third of the way up or leaks through a sunlit wall. Local
   comparison follows the gradient and still stops dead at an edge.

4. **Key on luminance, but pick the frame.** Luminance separates sky from
   land almost perfectly in daylight (0.4% distribution overlap) and
   collapses at night (37%) — see the findings doc. Because the camera is
   locked off, the correction only has to work on ONE frame and then serves
   the whole shoot, so the tool should run on a bright frame. The app can
   choose it: the 25 vote samples are already decoded, so scoring
   separability across them is nearly free. Saturation is the only signal
   that does not collapse and belongs in the mix as a tiebreak.

5. **Use the vote's confidence to triage.** The 26-level vote already knows
   where it is unsure, and the uncertainty sits exactly where the errors are.
   Surfacing "here are the four places I am not confident" turns an
   open-ended painting task into a short confirm/flip pass — a much better
   fit for something done once per project.

**Cost ladder:** local flood fill + guided snap, click only (small,
self-contained, most of the value) → stroke-based corrections stored as
intent (the schema work; the part worth doing properly) → confidence triage
UI (small once the above exists) → graph cut / GrabCut (genuinely better on
hard cases, no Apple builtin, a real port).

**Wrinkle:** drag on the preview is already taken by text placement, so this
needs an explicit mode. Fine on the Mac, more intrusive on iPhone.

### Design mirrors for the tabbed editor rail — iOS remainder

**Raised:** 2026-08-31, out of the text-overlay spike · **Narrowed:** 2026-08-31 — macOS drawn (30b5836), then rebuilt for Text Features

The macOS Edit window's specs are current: `macOS/photo-viewer.svg` /
`.text.svg` / `.frames.svg` / `.masks.svg`, all four carrying the four-tab
rail, verified against the running app and ✅ in the macOS INDEX
(centre-snap guides, the More… popover, model-missing and mask-file-missing
states desc-only — draw them if they matter for sign-off). Still owed: the
six iOS viewer SVGs (`project-photo.viewer.*.svg` family) are stale against
the tab bar and the stacked layout's Text/Frames/Masks pages have never been
drawn; mirror once the iOS pass happens.

### iOS tab host still folds tabs 5+ into UIKit's invisible "More" controller

**Raised:** 2026-08-30, while fixing the Collections phantom back button

The six-tab `TabView` makes UITabBarController fold Collections and Settings
into its legacy `UIMoreNavigationController` on iPhone — the system tab bar is
hidden, but the fold still happens. Its glass bar floated a phantom back
button over both tabs and pushed their content down a bar's height;
`hiddenMoreNavigationBar()` (`App/LetsLapseApp.swift`) now hides that bar and
disables its pop gesture with public API. The fold itself remains: folded
tabs live inside a navigation controller nobody asked for, one UIKit
behavior change away from a new artifact. The durable shape is the macOS
pattern — a ZStack + `switch selectedTab` (only the selected tab mounted,
paths already hoisted to ContentView) — at the cost of unhoisted per-tab
@State (Projects' filter/search text) resetting on tab switches, which is
what to weigh before doing it.

### Collections wide layout: bottom Add/Export row collides with the floating tab bar on iPad

**Raised:** 2026-08-30 (pre-existing; seen while verifying the up-the-fold rework)

`CollectionDetailView.wideLayout` pins "+ Add clips | Export collection" to
the bottom of the right column with 10pt of clearance. On iPad the floating
tab bar pill is wide enough to sit on top of the Add button (Export, further
right, stays clear). Needs tab-bar clearance like the portrait layout's
140pt spacer — or the row moved above the pill's band.

### Tall clips still own the whole portrait fold in the collection builder

**Raised:** 2026-08-30, out of the up-the-fold rework

A 9:16 clip in portrait fills the screen width by design ("never letterboxed
by default"), which at ~630pt tall pushes the caption row and timeline below
the fold — the one case the 2026-08-30 rework doesn't rescue. The "Apply
letterbox" pill already shrinks it to 240pt on demand. Decide whether tall
clips should default to the letterboxed preview (or a ~340pt cap) inside the
collection builder specifically; that reverses a deliberate v1 choice, so it
is Steven's call, not a drive-by.

### Render progress publishing storm — UI staggers during any render

**Detail:** [perf-audit-2026-08-29.md](perf-audit-2026-08-29.md) (finding A +
ranked fixes P1) · **Raised:** 2026-08-29

Every render publishes per-frame progress through `@Published` state on
`AppModel` itself, so each engine tick re-evaluates the whole mounted view
tree — plus an app-root `.onChange(of: model.progress)` and, on macOS, a
whole-log-file re-read per emit. Fix at the sink (5–10 Hz gate), move run
progress off `AppModel` onto a processing-only observable, ring-buffer the Mac
job log tail, and throttle the `ImageStacker`/`TimeSliceRenderer` emitters.

### Editor sliders unusable on big interval shoots — O(frames) body work + per-settle library persist

**Detail:** [editor-performance-plan.md](editor-performance-plan.md) ·
**Raised:** 2026-08-29 · **Stages 0–3 landed same day — Mac bench 4.8 →
58.4 ticks/s; on-device A/B on the iPhone 16 Pro (real 260-capture library,
1,250-frame shoot): 0.2 → 57.7 ticks/s, ~290×. The sibling audit's 10 Hz
progress gate landed with it after the 16 Pro recording of a blend start
freezing transitions for ~a minute. Same evening, the processing-flow pass
landed off that recording (plan doc header): hero-once-per-run,
`ProcessingProgressModel` (sibling P1.2), `source(for:)` existence tickets,
blend orchestration off the main actor + `.utility` workers — Mac A/B: main
thread during a live blend 100% busy → 6%; 16 Pro A/B (2026-08-30, real
1,249-frame shoot): main-thread share 15% → 3.4%, biased against the fix
(the before window missed the launch wedge). Fixed build installed on the
16 Pro. Owed: Steven's feel-check of the recorded flow + Cancel, iPad/12
Pro installs, stages 4–6, uncommitted.**

Grading sliders miss touch-downs and catch up seconds late on every device
(iPad M3 included — the mechanisms scale with shoot length and library size,
not silicon; photo-mode stills are unaffected). Six ranked mechanisms, the
top two measured: the editor rebuilds the full frame-URL list ~a dozen times
per slider tick on the main thread (10.9 ms/call at 1,480 frames, measured),
and every 100 ms debounce settle JSON-encodes the whole library on the main
actor, clears every project's size cache, and invalidates the entire mounted
view tree — which also fires a second hidden 1400 px render of the same grade
behind the cover and a per-frame `fileExists` storm in list bodies (the same
hot stack the sibling audit's 12 Pro trace caught). Plus: ~60 MB of Metal
scratch allocated per preview render (`restage()` unused by previews),
zombie renders holding the shared 4-wide media queue, RAW-decode-per-step
scrubbing, and the video editor swapping a fresh `AVVideoComposition` per
settle. Fix is staged Mac-first in the plan doc (seeded 1,480-frame bench +
AX-driven drags + Time Profiler gates); everything is shared code, so iOS
gets each win for free. Sibling: the render-progress storm entry above —
stage 6 coordinates both on the structural `@Observable` question.

### Standalone phone↔iPad transfer — make the pairing work without a Mac

**Detail:** [perf-audit-2026-08-29.md](perf-audit-2026-08-29.md) (findings
B–D, both measured runs, the on-device profile) · **Raised:** 2026-08-29
after a 5.1 GB iPhone 12 Pro → iPad pull ran hot, thermally stalled, and died
at 4.6 GB with `NWError 60`, discarding the staged tree. The Mac relay is a
bench workaround only — the iPad exists to remove the Mac dependency, so the
radio path itself is the product surface.

Measured basis: same phone/project did 12.6 MB/s over USB (thermal ≤2) vs
7.4→1.3 MB/s over Wi-Fi (thermal critical in 3 min), ack window pinned full
both times — the radio path is the bottleneck and the heater. The data
connection is already infrastructure-only; the AWDL duty is the *three*
side-radios (client browser scanning + both idle listeners advertising).

- **Phase A (started 2026-08-29):** negotiated-interface logging on both
  ends, client browse pause during pulls, both idle listeners withdraw their
  Bonjour advert while a transfer is in flight
  (`llProjectTransferPullState`), keep-awake on both roles, per-file progress
  emit throttled. Acceptance test: the same 5.09 GB pull, instrumented.
- **Phase B — resume (plan §4):** `have` set on `requestTransfer`, keep
  partials on failure, auto-reconnect; turns a dropped hour-long pull into a
  30-second reconnect. Friendlier failure copy than raw `NWError 60`.
- **Phase D — direct peer-to-peer (started 2026-08-29):** the field case was
  broken by one missing flag — discovery was P2P-capable but `PTLink`'s data
  connection never set `includePeerToPeer`, so two devices with no shared
  network would find each other and hang at pairing forever. Flag added; the
  `via …` log names the winning path (`awdl0` = direct). Field validation
  pending (cross-SSID bench test = a no-router simulation). Later: consider a
  "direct connection" affordance if the framework prefers a bad AP over a
  good AWDL path in practice. Same gap likely exists in the camera remote's
  `LocalNetworkTransport.connect` — audit separately.
- **Learned on the bench (2026-08-29 evening):** thermal was the *casualty*,
  not the cause — a cool-pack run at thermal 0 crawled at the same 1 MB/s.
  The home network is 2.4 GHz ch11/20 MHz ("blanickaback"), and an
  infra transfer crosses that channel twice; single-digit-Mbit reality. The
  fast run was USB (wiredEthernet), never Wi-Fi.
- **Phase C:** serving-side UI churn (sharing chip out of ProjectsView's
  observation, catalogue-walk TTL), screen-dim during transfers (design
  pass: thermal/interface/rate readout in both transfer UIs), and the
  `cleanUpOnDisappear`-never-stops-the-camera backstop.

Open questions for the next instrumented run: infra band/RSSI vs yesterday,
charging-heat contribution (both measured runs were cabled = charging), and
whether advert-quiet alone recovers most of the rate.

### Time slicing — the time gradient that scrolls across the frame

**Detail:** [time-slicing.md](time-slicing.md) · **Raised:** 2026-08-28 ·
**Stages 1–4 landed 2026-08-28 (engine, orchestration, verifier, Adjust UI),
plus the same-day first-output review round (plan §7a) — UI sign-off + SVG
mirrors, the stage-5 processing loader, then feathered edges (promoted) open**

*Review round: reading order flipped to earliest-first (default
`newestEdge` .right/.bottom, UI control "Time starts"); the primary temporal
control became **Spread as % of the clip** (seeded ~25%, amber under 5%,
frames stay the stored recipe via exact two-way `TimeSliceGeometry`
mapping); the "1/10-resolution animation" and "units bug" findings dissolved
on probing — the registered files are full 12 MP and the sampler shifted
exactly the commanded 30 frames (the reviewed .mov was a transcode; the
sub-frame lag was luma-measurement degeneracy, which also forced an
overlap-floor + first-difference fix into `timeslice_report.py`).*

*Stage 3 E2E on the real Mac library: one headless Create
(`LL_ADJUST=stills LL_TIMESLICE="segs:8,lag:3,…" LL_ADJUST_CREATE=1`)
registered three blends on the newest dawn shoot — regular clip (no recipe),
329-frame sliced animation (350 − the 21-frame spread, exact) and poster,
both recipe-carrying and recipe-named. `slicing` phase + progress band,
`openBlend` rehydration, Cancel bridged to the renderer. Mirror debt for the
sliced rows' project-detail copy rides stage 4's design pass.*

*Landed: `TimeSlice.swift` + `TimeSliceRenderer.swift` in the Kit (25 tests,
all numeric — bands measured against the commanded master frames), `lapse
slice` in the CLI, `tools/timeslice_report.py` (independent ladder
measurement — `TIMESLICE PASS` at exact commanded slope on rendered slices,
INCONCLUSIVE by design on flat scenes). Real-footage E2E: the 1,587-frame
12 MP "Blended 10 long" blend sliced in 72.6 s at 265 MB peak — flat memory
measured true against a ~1.1 GB cycling spool. One real trap re-found:
`FileHandle.read`'s autoreleased Data made the spool loop's memory track
bytes read 1:1 — the transfer pump's exact bug — fixed with a per-frame
autoreleasepool. No iOS anything touched, per the sequencing decision.*

Partition the output frame into N bands, each sampling a different point on
the source timeline (per-band frame lags), so a sunrise travels across the
frame during playback; the single-frame variant is the whole-day-in-one-photo
poster. Interval and Video shoots, inside `+ New blended clip`. The plan doc
answers the brief's seven open questions from the code and overrides the brief
twice, both load-bearing: the §4.7 "bands not frames = one frame of memory"
claim is wrong for the animation (true only for the poster — the honest floor
is ~half the spread, so the design is a banded ring-file spool on disk with
flat RAM), and stage 1.5 moves from a pre-encoder tap to the **last tail pass
over the finished blended clip** — the only point where every engine converges
on uniform, final-geometry, grade-baked frames (mixed-resolution ramp shoots
are per-segment sized at the tap; the Mac runner blends out of order). That
placement also makes the parked "re-slice an existing blended clip" path the
same code minus UI, and dissolves the burst-resolution-straddling question.
Sliced outputs register as ordinary `BlendProject`s (animation `.video`,
poster `.image`), so archive/transfer/storage/delete are inherited with zero
allowlist changes. Sequencing decided 2026-08-28: **build first, macOS first**
— engine stages verified through Kit tests, a new `lapse slice` subcommand and
the Mac app, no iOS simulators downloaded for this job; UI later, code-first.
Display names carry the recipe (`timeslice-vert-left-segs_24-lag_2`; width
auto-calculated). All seven brief questions answered 2026-08-28 (offsets in
frames · trim · full-source PNG poster · master resolution, no upscaling ·
frame-space ramps), and the Adjust preview became the **§6a processing
loader**: every blend run's Processing hero builds up band by band — a real
full-source time slice of the shoot at the output's aspect, bands jumping in
with progress — with the checklist card moved above Cancel and the cancel
caption removed. Still open (plan §9): whether the throwaway master forces
`hevcMain10` when "Include regular timelapse" is off.

### Import a project from another device (local network)

**Detail:** [project-transfer-plan.md](project-transfer-plan.md) ·
**Raised:** 2026-08-27 · **Phases 1–3 landed, all uncommitted** ·
*revised 2026-08-27 — payload strategy, resume, AirDrop/USB*

**Phase 3 landed 2026-08-28 — every direction now works.** `ProjectTransferServer`
widened to `#if !os(watchOS)`, so a Mac offers its library through the same
listener, the same chip in the same Projects header, and the same Settings ▸
Advanced opt-in. Device identity is `Host.current().localizedName` on macOS
(`UIDevice` on iOS) and the model string picks the picker's glyph.

**The one genuinely different piece is the stand-down.** iOS gets one free —
the app backgrounds and the listener stops — but a Mac scene never backgrounds,
so an armed Mac would advertise its whole library until the app quit. The rule
is `ProjectTransferServer.idleTimeout`: 15 minutes with nobody connected and it
stops itself, the clock reset by anything meaning a human is still present
(arming, a peer connecting, a transfer finishing). It applies on iOS too — a
good second rule there, just not the only one.

**Verified 2026-08-28, iPad Air M3 ← this Mac:** "Blended 10 long" — 5.91 GB,
1,588 source files plus its blended clip — installed into the iPad's library.
Peak serving footprint 223 MB, ack window bounded at 33 MB.

**Serving throughput on a Mac is bounded by wherever the library lives**, and
this was demonstrated the hard way: on the old USB drive (**692 KB/s raw**) the
pump managed 0.7 MB/s with its window sitting at 1–6 MB of 32 — starved by disk,
not throttled by protocol. On the SSD that replaced it the window runs full
(27–33 MB) and the bottleneck moves to the receiving device's Wi-Fi. Worth
knowing before anyone reads a slow Mac→iOS transfer as a network problem: check
the window depth first — low means disk, full means wire.

**Phase 2 landed 2026-08-28.** The import client is now every platform that has
a library, not just the Mac: `ProjectTransferClient` widened to
`#if !os(watchOS)`, and the whole flow moved into one shared
`App/ProjectTransferImportView.swift` that macOS hosts in its `Window` and iOS
and iPadOS present as a sheet. Create's **"Import a LetsLapse project…"** row is
now the single door on both platforms — it asks *From a file…* or *From another
device…*, which keeps `.lapse` import where it has always been and gives the
network path a home that isn't a menu bar. Also in: a free-space refusal checked
before a byte moves (and flagged on the project row itself, which matters far
more on a 128 GB phone than on a Mac), and `LL_TRANSFER` as an iOS launch hook.

**Verified 2026-08-28, iPad Air M3 ← iPhone 12 Pro over Wi-Fi:** "Long psycho
i12", 7.33 GB across 2,869 files, installed into the iPad's library with
`Incoming/` swept clean afterwards; the serving phone's footprint peaked at
78 MB and the ack window never exceeded 28 MB against its 32 MB bound.
Throughput ranged 14 MB/s down to 1 MB/s and back as Wi-Fi and the 12 Pro's
thermals varied — flat memory throughout, so that is the wire, not the engine.

**Mac→iOS is Phase 3 above, and now works.**

**What Phase 1 shipped**, verified end to end (a project moved simulator→Mac
and every file matched the manifest byte for byte, and again through the real
Import window): `AppModel.LibraryActivity` and all its registration sites ·
`Shared/ProjectTransferProtocol.swift` (typed 1+4-byte framing, control /
data / cancel) · `ProjectTransferServer` (iOS) · `ProjectTransferClient` +
`Remote/ImportWindow.swift` (macOS) · `"Incoming"` in `libraryItemNames` ·
`ProjectArchive.transferableSubfolders` · the `importProject` split into
`installStagedProject` · `tools/transfer_probe.swift` · the SVG mirrors.

**Two deliberate departures from this plan, both narrowing:** the service is
`_letslapse-xfer._tcp` and the salt `…transfer.v1` (the plan says
`_letslapse-library._tcp` / `…library.v1`); and **`requestTransfer` carries no
`have` set, so there is no resume** — a dropped pull discards its partial tree
rather than stranding gigabytes nobody can spend. Resume is §4 and needs the
vocabulary to grow the `have` list; `Incoming/` already has the right shape,
the right home and the 24-hour launch sweep for it.

**Device-verified 2026-08-27 on the iPhone 16 Pro over USB:** an 11 GB project
(612 files) moved byte-for-byte in 267 s at 41 MB/s with the app's peak
footprint at **90 MB**; a client killed at 25% aborts the server in 0.7 s and
leaves it serving normally; 293 projects list in ~0.4 s; the real Mac Import
window completed a phone→Mac import end to end. The device run found three
bugs a simulator structurally cannot (§3's semaphore recipe doesn't bound
anything, `FileHandle.read`'s autorelease made memory track bytes read 1:1, and
a cabled device's two-interface race broke newest-wins) — all fixed, all
written up in the plan doc's header.

**macOS Local Network permission, learned the hard way 2026-08-27.** It is
granted per COPY of the app, keyed on the binary rather than the bundle id, so
every build from a new location becomes a new grantee and the Settings list
fills with identical LetsLapse rows — all switched on, none of them the one
running. Two consequences now handled in code: `NWBrowser` never recovers from
`.failed`, so the Import window rebuilds it every 2 s and picks up a
newly-granted permission on its own (it used to need a close and reopen); and
the refusal screen names the running copy's path, offers Show in Finder, and
opens Settings via the `privacy-localnetwork` anchor. **`tccutil reset
LocalNetwork` does nothing** — Local Network is not a TCC service on macOS
(`kTCCServiceLocalNetwork` is absent from `tccd`), so there is no CLI reset and
stale rows can only be left to age out. Running one copy from one fixed
location is what stops them accumulating.

**Thumbnail coverage — fixed 2026-08-28.** Tiles no longer ride with the list.
Each row asks for its own as it appears (`requestThumbnail` → `PTThumbnailReply`)
and the serving device GENERATES one when its cache has none, persisting it
under the same key the local grids read — so it costs one decode ever, and the
local Gallery gets it for free. That is the §2 design, and it fixes the real
problem: the old eager path was capped not by its 3 MB budget but by coverage,
because `DiskThumbnailStore` only holds a tile for an asset some grid has
actually drawn. Measured on this Mac: **79 of 79 rows drawn**, 1.5 MB of tiles,
10.3 s on the first pass and instant on the second; visually confirmed on the
Mac's picker against a serving iPad, including three projects that had arrived
by transfer minutes earlier and had never been drawn locally.

**Still owed:** iPad→Mac (every Mac-side run so far has been from an iPhone).
Settings ▸ Incomplete Transfers is not built: with no resume there is nothing
to resume, and the sweep reclaims the disk. Resume itself (the `have` set) is
the remaining §4 work.

Move a ~1–20 GB project device-to-device over the local network with no
intermediate file on either side: iPhone/iPad serve behind a six-digit code,
Mac/iPhone/iPad pull. A new `_letslapse-library._tcp` listener, deliberately
separate from `CaptureRemoteListener` (different lifetime, different grant —
serving the whole library is not the same act as driving the shutter), and a
typed length-prefixed frame format carrying JSON control beside raw payload.

**The payload is files, not an archive.** lzfse over DNG/ProRes saves close to
nothing, so the compression pass buys a rounding error and costs heat on a
thermally marginal phone — while file-by-file makes the transfer **resumable**
with the filesystem as its own ledger (stage into `Incoming/<projectID>/`,
`.part` until complete, reconnect with the set you already hold). A sequential
Apple Archive stream has no "start at entry N", so an interruption at 90% throws
away 90%; that is the trade this reverses. Phase 0 measures the real compression
ratio on Steven's own footage to confirm it before committing.

**Prerequisite for everything else:** the app has no central busy flag — capture
lives in `CameraController`, blending in `AppModel.stage`, and both archive
exports in view-local `@State` — so a `LibraryActivity` registry lands first.
Two smaller traps already identified: `"Incoming"` must join
`StorageLocation.libraryItemNames` or a storage move strands a half-finished
12 GB transfer, and the `["source","blends","notes"]` install allowlist must
become one shared constant or untransferable bytes get sent and then deleted.

**AirDrop already works** via the share sheet and needs no work — with the
caveat that it materialises the whole `.lapse` to temp first (peak disk ≈ 2×,
though `exportProject` refuses cleanly when there is no room). **USB is free**:
listening on all interfaces means a cabled iPhone is found by the Mac's browser
with no protocol change — the only work is a picker label, and what interface
type a tethered device reports is a hardware check, not an assumption.

Phased iOS-serve → Mac-import (**done**), iOS import (**done**), Mac serve
(**done**). Both phases' UI was built app-first at Steven's direction and mirrored
in the same unit of work: `iOS/projects.sharing.portrait.svg`,
`iOS/settings.advanced.portrait.svg`, `iOS/create-home.import-source.portrait.svg`,
`iOS/library-import.browse|progress.portrait.svg` and the five
`macOS/library-import.*.svg` files.

### Holy Grail ramp actuation: bench verification on both pipelines

**Detail:** [holygrail-ramp-actuation.md](holygrail-ramp-actuation.md) ·
**Raised:** 2026-08-27 · **Code landed 2026-08-27 — verification owed**

*Shipped on `ios-app`: the JPEG live-blend path now arms the ramp AFTER
`lockConstituentSwitchingForRun()` rather than ~1.3 s before it;
`applyHolyGrailExposure()` returns a named outcome instead of three unlogged
early returns, with one bounded retry folded into the existing settle hold;
and both blend controllers now report a ramped run whose commanded exposure is
nil (`RAMP NOT DRIVING`, plus `kind: "ramp"` in the `issues[]` trail on the
JPEG side).* The bug: three consecutive Dynamic runs on the 16 Pro logged a
ramp and drove nothing — engine target and delivered frames finished 4.3 stops
apart with `EXPOSURE DIVERGENCE` appearing zero times, because a nil commanded
target skipped the guard that was supposed to catch exactly this. Owed before
this leaves the list: **(a)** a bench run on each pipeline (JPEG, then DNG
output enabled) against the pass conditions in the brief — in particular
frame 0's ISO/shutter within a quarter stop of frames 1–3, which is the
regression test for the original purple frame; **(b)** confirm or kill the
hypothesis that a virtual device with constituent switching unlocked is what
refuses `.custom` — the fix does not depend on it, but the next person's
mental model does; **(c)** the product call on whether a run whose ramp cannot
actuate should refuse to start rather than only saying so in the log.

### Dim-screen-during-shoot: mirrors, Watch verification, and the composed A/B

**Detail:** [fieldtests/2026-08-25-thermal-bench.md](fieldtests/2026-08-25-thermal-bench.md) ·
**Raised:** 2026-08-25 · **Implemented 2026-08-25 (code-first per Steven) — mirrors + follow-ups owed**

*Shipped on `ios-app`: Settings ▸ Advanced ▸ "Dim screen during shoot" (ON by
default), `ShootScreenDimmer` (brightness floor + black cover + tap-to-peek +
restore on stop/exit/background; one `ShootDimming` modifier because
CaptureView's body sits at the type-checker's budget), Watch toggle in the
recording controls page, wire command `setDimDuringShoot` (the one setter
accepted mid-run, by design), `dimDuringShoot` in the state frame, and
`--dim on|off` in shoot.py run+fleet. Bench-verified: the A/B where dim-ON
completed a 20-min psycho arm the matched dim-OFF control could not
(12 Pro, veto at T+18.2).* **2026-09-05: (a) is superseded for iOS** — the row has been
redesigned into a Settings ▸ Display section and renamed *Blackout
viewfinder*; see the Display job at the head of this list, which carries the
mirrors (including the blacked-out screen itself, drawn for the first time)
and the answer to Steven's green-indicator question. Owed before this leaves
the list: **(a)** SVG mirrors after sign-off — the watch controls page, which
now waits on that rename;
**(b)** Watch-side verification on the real wrist (toggle round-trip,
pending states); **(c)** repeat the A/B under the monitor test card's
constant light (today's evening pair carries an ambient confound the
result survived but shouldn't have to); **(d)** the composed test: Safe +
dim vs psycho + dim on the 12 Pro — Safe attacks the floor load, dim the
OS margin, and the field default should be whichever pair holds a 2-hour
run.

### The 12 Pro locks whenever LetsLapse dies hot — and Never doesn't matter

**Raised:** 2026-08-25 · **Not started**

Observed ≥6× today (5 thermal vetoes + one post-collection console-detach
kill after a *clean* arm): whenever the app dies on a hot device the phone
ends up locked, despite Auto-Lock → Never, and a locked device refuses
`devicectl` launches — an unattended rig that dies stays dead AND
unreachable. Steven's correlation: it never locks otherwise; once woken it
stays awake. Mechanism unpinned. Discriminating test queued: hand-launched
short shoot + normal exit (cool, then hot) vs devicectl-launched ditto —
separates "dev-tools launch" from "app death" from "hot at death". Whatever
the mechanism, the suspension-lifecycle job (below) should treat
"post-outage device may be LOCKED" as a first-class state in its recovery
design, and the field checklist gains: physical access is the only cure.

### `collect_arm` can hand back the previous run's capture log

**Raised:** 2026-08-25 · **Not started** · small

`shoot.py`'s `collect_arm` pulls the newest `capture_log.json` on the
device; an arm that died mid-run registers no project, so the pull silently
returns the *previous* run's log as if it were this one — bit twice today
(Phase A returned the morning field log; the dim-OFF control returned the
dim-ON arm's log, nearly inverting the A/B verdict). Fix: parse the pulled
log's `startedAt` and require it inside the arm's window; otherwise report
"no capture log from THIS run — the arm died; see the liveblend experiment
log" (which the same collection already pulls and which is the honest death
record).

### Holy Grail ramp servo limit-cycles against the ISP's exposure quantization

**Detail:** [fieldtests/2026-08-25-dawn-scheduled.md](fieldtests/2026-08-25-dawn-scheduled.md) §2 ·
**Raised:** 2026-08-25 · **Implemented 2026-08-25 evening — bench validation owed**

*Shipped in `HolyGrailRampEngine`: deadband (0.12 stop) + 3-window dwell +
10-window reversal refractory + 1-stop emergency bypass, on for every
Dynamic run, zero-parameters = bit-identical legacy (33 legacy tests
untouched, 4 new gate tests). Worst case at the coarsest latch region is a
~40 s sub-visible breathing instead of per-window flicker. Owed: the
test-card scripted-ramp run through the short-shutter region, gated by
`source_flicker_report.py`, then a real dawn arm and one DNG confirmation
arm.*

The 2026-08-25 iPad dawn run carries 13 oscillation events (up-down-up
exposure pumping, ~0.09–0.16 stops per flip): at short shutters the ISP only
latches coarse discrete exposure states (0.18–0.37 stops apart at the ISO 18 /
sub-200 µs end), the wanted exposure sits between two of them, and
`HolyGrailRampEngine.advance` has no deadband, no hysteresis and a one-window
measurement delay — so the servo flips between the two latched states every
window. Fix in the Kit: commit a move only past a deadband (~1/6 stop) that
has persisted K≈3 consecutive windows in one direction (dwell), hysteresis
sized above the local actuation quantization, an emergency bypass for >~1-stop
errors. Unit tests: synthetic quantized actuator under a slow ramp → monotone
steps, zero steady-state toggles; constant scene stays a no-op. Verify on the
monitor test card's scripted brightness ramp, then a real dawn arm. Gate
before/after with `tools/source_flicker_report.py`. Policy-only change — no
bracket construction or device-write path touched, so DNG capture is
structurally unaffected; run one DNG arm to confirm.

### Dynamic (holy grail) runs must end where AE would meter the ending scene

**Detail:** [fieldtests/2026-08-25-dawn-scheduled.md](fieldtests/2026-08-25-dawn-scheduled.md) §1 ·
**Raised:** 2026-08-25 · **Implemented 2026-08-25 evening — bench validation owed**

*Shipped: the anchor drifts toward the device AE's own absolute opinion
(`exposureTargetOffset`-derived `aeSceneEV`, bias-inclusive) at a hard cap
of 1/20 stop per window with a 0.25-stop deadband and its own EMA — an
outer loop an order of magnitude slower than the servo, so the 2026-08-15
runaway class is excluded by construction; the absolute reference also
cancels the luma meter's ×1.75 crush amplification. Engine: shared, so DNG
and JPEG paths both fix at once; without an AE reading the anchor holds as
before (3 new Kit tests; `holygrail: anchor drifting` LLog when the gap
exceeds half a stop). Owed: the test-card dark→bright scripted ramp ending
within ~1/3 stop of a fresh-AE control, then a real dawn.*

The frozen-anchor dark run: `anchorsToSeedExposure` locks the seed frame's
rendering for the whole run, so a 2 h 17 m sunrise ended 6.1 stops darker than
the same scene's fresh-anchor exposure (control shoot 1b), amplified 1.75× by
the whole-frame mean-luma meter's non-invariance (residual loop gain 0.43).
Two-part fix: (a) let the anchor drift slowly (~1/20 stop/window cap) toward
consistency with the device's live AE opinion (`exposureTargetOffset`), so the
run converges on AE's rendering without frame-visible steps — designed against
the 2026-08-15 positive-feedback runaway (drift gain far below unity, Kit
regression `testAConstantSceneNeverMovesTheRamp` plus a drift-converges test;
(b) make the meter clip-aware (trimmed/percentile luma) to cut the residual
gain. Needs the test-card bench (scriptable light curve) for closed-loop
validation before a dawn. Diagnostic that found it: `measuredEV − appliedEV`
flat at −2.81 all run. Related: the scene-referred-meter note in the JPEG WB
brief.

### A suspended shoot must die honestly or resume deliberately — never zombie

**Detail:** [fieldtests/2026-08-25-dawn-scheduled.md](fieldtests/2026-08-25-dawn-scheduled.md) §3 ·
**Raised:** 2026-08-25 · **Not started**

iPhone 12 Pro, unthrottled 3 s: thermal critical at +16 min, iOS forced the
cool-down lock at ~+32 min, the app suspended for ~103 minutes (proven by
`procMs` 285 s across a 108-min wall gap), and the run neither ended nor
resumed — window advancement is frame-driven and the watchdog clock pauses in
sleep. On wake the backlog close-storm fed `consecutiveProcessingFailures`,
which killed the run one second after it had just delivered a good frame, and
the resumed camera was silently back in plain AE (frame 635). Work: detect
the outage (interruption notifications + wall-vs-monotonic gap at wake) →
`issues[]` entry with the real reason and gap; backlog catch-up windows never
count toward the kill guard; on wake either re-assert the ramp's custom
exposure or end as `endReason: systemPressure`; author EXIF DateTimeOriginal
from `capturedAt` so late-written windows carry capture time (rides the JPEG
EXIF job). Mirror in both blend controllers. Plus prevention: thermal input
to the AIMD ceiling (step down at serious, floor at critical) and the planned
starvation repace, so unthrottled degrades instead of summiting into the OS
veto; scheduled unattended shoots should warn on (or default away from)
unthrottled on OIS-class phones.

### 12 Pro OIS park at thermal critical — mitigation decision

**Raised:** 2026-09-02 · **Steps 1+2 implemented 2026-09-02 — bench envelope pending** · report:
[2026-09-02-framing-shift-pattern.md](fieldtests/2026-09-02-framing-shift-pattern.md) ·
decision + implementation notes:
[2026-09-02-framing-shift-decision-analysis.md](fieldtests/2026-09-02-framing-shift-decision-analysis.md)

*Shipped on `ios-app` (uncommitted): the blend tap streams at twice what the
depth needs instead of the pinned rate, and drops to the depth's need when
the camera's `systemPressureState` reaches serious (Apple's prescribed
mitigation); iPhones end any run at device-wide thermal critical with
`endReason: tooHot` and the last two outputs + sidecar lines dropped, and
refuse to start there; per-window camera pressure in both logs. Verified on
the 12 Pro: stream 10 → 1 fps at depth 1 @ 2 s, `simulateTooHot` (DEBUG
remote command) ended a 23-window run at 21. Owed: the 2 h × 3 warm-ambient
envelope arms, the design mirror for the idle thermal chip (never drawn),
and a decision on the open-ended depths' serious-pressure rate (3 fps).*

`tools/framing_shift_report.py` (new) swept every project with JPEG sources
(28 projects, ~17 k frames): all six persistent framing steps in the corpus
are on the iPhone 12 Pro, all land in a window at thermal **critical** (0 over
2653 serious frames), and in the three post-gate runs the step sits in the
`serious → critical` transition window itself. Each is a pure 44–64 px
gravity-axis translation with identical lens f-number and dimensions either
side, so it is the lens-shift OIS actuator dropping to its gravity stop — no
API controls it. The brief's four software suspects (geometry change, implicit
EIS, constituent hand-off, GDC toggle) are each ruled out in the report.

Decision owed (Steven), then build — no post-capture reframing by design:
keep the phone out of critical (thermal → AIMD ceiling, warn on Dynamic/
unthrottled for OIS-class phones in scheduled shoots), surface the gate's
`framingChanged` on the capture screen + Field Notes, optionally pause at
critical on OIS-class devices (the lens re-centres when the servo returns),
and a bench repro on the test card: 12 Pro virtual-triple vs physical-wide
pinned, and a 16 Pro driven to critical (never reached in any logged run —
its sensor-shift immunity is plausible, not proven).

### Pin digital stabilization off on tap connections, and log it

**Raised:** 2026-08-25 · **Not started** · small

The 2026-08-25 investigation re-confirmed the interval/blend frames can never
be digitally stabilized today (only `movieOutput` ever gets a stabilization
mode; data-output connections default off) — but that guarantee is implicit.
Set `preferredVideoStabilizationMode = .off` explicitly on the liveBlend /
test-card / framing tap connections where supported and record it once in the
session log, so the next tripod-jump investigation (they recur: Praha
2026-08-23, dawn 2026-08-25 — both were OIS hardware sag at thermal critical,
which has no API off-switch) starts from a logged fact instead of a code read.

**Raised:** 2026-08-24 · **Implemented 2026-08-24 — device verification pending**

*Shipped on `ios-app`: the frame-alignment gate (`FrameAlignmentGate` in the
Kit, wired into `LiveBlendController`; rejects confidently-displaced frames
before they ghost a stacked window — the Praha 2026-08-23 OIS-sag events,
measured at ~63 px vertical at thermal critical), honest per-window
`rejectedByAlignment` stats plus a machine `issues[]` trail in
`capture_log.json` (thermal, framing glitches, constituent hand-offs, end
reason), run-scoped constituent-switch locking, the idle thermal warning chip,
and the full Field Notes flow (audio/issue/text notes per project in `notes/`,
both entry points, on-device speech review). Kit tests + sim E2E pass.*

Still owed before this leaves the list: **(a)** bench repro on the 12 Pro —
heat to critical with back-to-back runs, tripod on a static scene, expect gate
rejections logged and clean output; and a nominal-thermal control run with
**zero** false rejections (the gate must never thin a healthy shoot);
**(b)** a `.lapse` export→import round trip carrying `notes/` (the import
allowlist fix); **(c)** the spoken-memo → transcript-prompt path on a real
device (sim lacks on-device recognition); **(d)** SVG mirrors after UI
sign-off — capture-screen thermal chip, project-detail notes rows, the
field-note flow screens (no iPadOS/macOS project-detail SVGs exist at all —
pre-existing gap).

### Interval shoots get the video "New blended clip" screen

**Detail:** [interval-adjust-unification.md](interval-adjust-unification.md) ·
**Raised:** 2026-08-24 · **Phases 1–2 implemented 2026-08-24 — phases 3–4 open, phase-2 sign-off pending**

*Phase 2 (2026-08-24, code-first per Steven): interval shoots now get the
real warp timeline — per-stretch **blend depths** ("5:1" chips, custom to the
frame count) absorbing the old slider, the capture-clock axis (frame-count
fallback), the "One long exposure" mode row, the unified estimate card, and
wide layouts. `IntervalWarp` compiles the schedule in the Kit (trivial
timeline ≡ the old constant schedule, per-stretch clock retiming);
`stackSequence`/`stackSequenceLinear` take `customWindows`. Verified: Kit
tests, three platform builds, headless Mac E2E on the real library (303
photos → 101 frames @ depth 3, timed from capture, warp in the recipe), Mac
wide + iPhone narrow screenshots via the new `LL_ADJUST=stills` /
`LL_ADJUST_CREATE=1` hooks. Owed: Steven's sign-off on the built UI, then
the SVG mirrors (`adjust.photos.portrait.svg` marked stale in the iOS INDEX;
iPadOS/macOS have no adjust SVGs — pre-existing gap), and a device pass.*

*Shipped on `ios-app`: every interval-style run now writes `frames.timestamps`
(plain photo-timer runs in `CameraController`; blend runs in both blend
controllers, off for Holy Grail where the ramp owns the file); stills projects
get probed `sourceWidth/Height` and a sidecar-derived `sourceDurationSeconds`
at registration, import, and a one-shot launch catch-up; and the shared stills
axis exists as `FrameAxis` in the Kit (photo editor lifted onto it,
`StillsPreviewLoader` staged beside `WarpPreviewLoader` for phase 2).
Deliberately invisible: badge/header lines are kind-gated so the new fields
change no screen. Side effect by design: fresh plain-interval blends now lay
out on the real capture clock (`ImageStacker` already honoured a covering
sidecar) — even pacing maps to the constant layout, so only genuinely uneven
shoots read differently, which is the sidecar's whole point.*

Verified 2026-08-24: Kit tests (13 new `FrameAxis` cases) and iOS-sim, macOS
and device builds all pass; the stills probe ran against the real Mac library
— 47/48 stills projects gained oriented dimensions (the 48th has its frames
missing on disk, correctly left nil), and exactly the 32 sidecar-backed
projects gained durations with none invented and all 14 video projects
untouched. Still owed for phase 1: one live interval run confirming
`frames.timestamps` lands in a fresh project's `source/` — the phase-1 build
is **already installed on the iPhone 12 Pro**; the phone was locked at bench
time, so unlock it and run
`./remote_probe <code> "setIntervalMode:basic,setFramesPerBlend:1,setIntervalSeconds#1,wait@1,startRecording,poll@2x6,stopRecording"`
(and once more at `setFramesPerBlend:3` for the blend pipeline).

Then phases 3–4 — spatial unification (reframe/canvas on stills renders,
codec chooser on both stills paths; grade maps turned out already unified:
the stacker's grade hook was source-anchored all along), then retiring the
`.photos` branch once Scanner is diverted to its own configure surface. Each
UI phase starts with the design-sync question.

### Field notes ↔ engine issue trail tie-in

**Raised:** 2026-08-24 · **Not started** · small

`capture_log.json` now records machine-detected issues (`framingGlitch`,
`thermal`, …) and Field Notes lets the user log the same vocabulary by hand
("Jumped frame(s)"). Two natural joints, deliberately not built yet: a
finished run whose log carries alignment/thermal issues could pre-tick the
matching Log Issue labels on the New-blended-clip screen, and the project's
notes list could surface the engine's own issue trail alongside the
hand-written notes. Design question first: whether machine entries live in the
same list or a separate "what the engine saw" section.

### JPEG Holy Grail locks white balance, and writes no EXIF

**Detail:** [jpeg-holygrail-wb-brief.md](jpeg-holygrail-wb-brief.md) ·
**Raised:** 2026-08-23 · **Implemented 2026-08-23 — device verification pending**

*Jobs A (slew-limited WB tracking for JPEG runs; DNG untouched via an explicit
`rawPipeline` flag) and B (EXIF authored on blended JPEGs) are implemented on
`ios-app`. Still owed before this leaves the list: a dawn/dusk JPEG arm on
device (WB tracks, EXIF present, flicker gate passes) and a DNG arm diffed
unchanged against a pre-change run. Job C (scene-referred meter) remains
record-only.*

`applyHolyGrailExposure()` sets `whiteBalanceMode = .locked` on every ramp write
and nothing restores AWB until the run ends, so the 2026-08-23 `jpeg sunrise`
shoot rendered two hours of sunrise through sodium-vapour gains: red ends at
**14 of 255 code values** — quantised away, unrecoverable in 8-bit. Acceptable
for DNG (grading latitude, and the stability is wanted); a show-stopper for
JPEG. Separately, the JPEG blend output is written with a GPS dictionary and
nothing else, so it carries no `DateTimeOriginal`, `ExposureTime`, `ISO` or
`FNumber` — the DNG author writes a real EXIF IFD, JPEG never has.

**The trap:** `applyHolyGrailExposure()` is shared by both pipelines, so a naive
edit changes DNG too — the fix has to be conditioned on the active pipeline.
The brief also records what is *not* wrong: the ramp did not run away (it held
to 0.12 stops over two hours), and the darkness is the seed anchor working as
designed.

### Capture Flat is dead on the blended JPEG path, and unlogged

**Detail:** [capture-flat-jpeg-brief.md](capture-flat-jpeg-brief.md) ·
**Raised:** 2026-08-23 · **Implemented 2026-08-23 — device verification pending**

*Jobs A (log truth: `captureFlat`, honest `captureMode: dynamic`) and B (flat
graded on the window's half-float mean, one 8-bit quantise, same curve as the
photo path) are implemented on `ios-app`; Kit tests cover the float finalize.
Still owed: re-run the §1 A/B on device — expect saturation ≈×0.80, contrast
≈×0.90, `captureFlat` in both logs — plus the shadow-push latitude check. Job
C (sensor-side probe) is open, and one product gap surfaced: the blend-strategy
picker only reaches the DNG pipeline; JPEG Auto always runs Zone.*

A measured A/B (projects `JPEG flat` / `JPEG non flat`, 2026-08-23, iPhone 16
Pro, Interval · JPEG · Psycho · Dynamic) came out pixel-identical: the blended
JPEG writer never reads the Capture Flat flag — the toggle only works for
photo-output stills and video. Where it does run it is a save-time re-grade of
the finished 8-bit JPEG (decode → grade → second lossy encode), which is the
post filter the setting exists to avoid. And no still shoot records the setting:
`capture_log.json` has no `captureFlat`, its `captureMode` is hardcoded
`"interval"` (Dynamic runs are indistinguishable), and `algorithm` says `zone`
for every Auto run. The fix that matters: apply the flat curve to the blend's
existing **float32 mean** at finalize — one quantisation, in flat space
(`finalizeMean` → `encodeGamma` already owns this) — which is metering-neutral,
unlike any tap-encoding change. Related, and downstream in value of, the WB
brief above.

### Storage accounting, and the Settings storage card

**Detail:** [storage-accounting-job.md](storage-accounting-job.md) ·
**Raised:** 2026-08-21 · **Not started**

Deleting every project on the bench iPhone freed 0.08 GB of a claimed 26.29 GB.
Capture staging is cloned into the project on adoption and never released, share
archives are never deleted, and the tmp filter matches neither — so the device is
sitting on **44.6 GB the app reports as `Cache Zero KB`**. Four defects, plus a
redesign of the storage card around reclaimable bytes rather than allocated ones.
Includes a one-time reclaim for installs already carrying orphans, and a
design-sync pass on the Settings SVGs.

### `swift test` fails on a dead scratch path

**Raised:** 2026-08-22 · **Not started** · small

`LinearDNGTests.testBlendsRealUntouchedSequence` writes its output to a
hard-coded absolute path from a long-finished Claude Code session
(`Kit/Tests/LetsLapseKitTests/LinearDNGTests.swift:156`), so `swift test` ends
`243 tests, 1 failure` with `writeFailed("The folder "untouched-blend-3.dng"
doesn't exist.")`. It only bites where there is real capture data — without an
untouched-DNG project in `~/Library/Application Support/LetsLapse/Projects` the
test `XCTSkip`s — which means it fails on the dev machine and passes anywhere
else. Point it at `FileManager.default.temporaryDirectory` (or a
`URL.temporaryDirectory` subfolder created by the test). Until it is fixed,
`.claude/skills/run-letslapse/SKILL.md` documents the failure as expected.

### A scheduled stop is logged as `endReason: user`

**Raised:** 2026-08-22 · **Not started** · small

The fleet smoke's three arms were stopped by `scheduleStop`, and all three
logs record `endReason: user` (they ran 9.99, 9.99 and 10.18 minutes against a
10-minute deadline, so the mechanism itself worked). `performScheduledStop()`
passes `source: .scheduled`, so the mapping to the log's `endReason` is
losing it. It matters because gate criterion V4 ("ran to plan") cannot
distinguish a planned end from someone tapping stop.

### `remote_probe` digest() shows almost nothing for a video run

**Raised:** 2026-08-22 · **Not started** · small

Add the video keys (`baseFPS`, `rampFPS`, `sequenceMode`, `segmentCount`,
`markerCount`) to `digest()` in `tools/remote_probe.swift` — a video run's
one-line digest currently shows almost nothing, because the digest was written
around the interval keys.

*(The other half of this entry is done: the script grammar now parses
`cmd:extra#value`, so `scheduleStop:minutes#60` is sendable and a shoot can own
its own deadline instead of being timed from the Mac. The header comment's
Shared-source list was corrected to three at the same time.)*

---

## Where the rest of the open work is recorded

Not everything known-broken has been turned into a job yet. Until it is, these
are the standing lists:

- **[letslapse-app-overview.md](letslapse-app-overview.md) §10 — "Current limits
  and sharp edges."** The honest known-issues list for the whole app: the ramp
  voiding the warp timeline, the reframe canvas framing an approximate frame,
  `ReframeTrack.clamp` never being called, the responsive-capture wedge, the
  test gaps. Several of these are jobs waiting to be written up.
- **[overview-audit-2026-08-10.md](overview-audit-2026-08-10.md) Part C.** The
  reframe UX triage table — problems, severity, and the use cases the feature
  should serve.
- **[design/](design/) — each platform folder's `INDEX.md`.** Per-screen mirror
  status; anything marked stale is outstanding UI work by definition.
- **Holy Grail Field Program** (artifact). The blend-strategy field programme:
  what has been run, what passed, what the next bench is for.

## Fine rotation (Edit screen · Rotation section) — follow-ups

Shipped 2026-09-02: a ±10° straighten slider on the Edit screen for stills
and video projects (`RotationSlider`, `FrameRotation` in the Kit), levelled
into every preview and baked into blended, guided and standalone-grade
outputs; keyframeable like every other control (rotation lives in
`PhotoAdjustments`, eased per frame by every bake); text layers ride the
levelled frame (existing layers turn with the picture, new ones start level,
and a travelling level carries them per moment). Owed:

- **Project cards and thumbnails are not levelled.** `ProjectThumbnailCache`
  decodes without the grade, so a levelled project's card still shows the
  raw tilt; the hero (`ProjectMedia`), grid and fullscreen sheet ARE levelled.
  Decide whether the card should pay for a grade render.
- **iOS viewer SVGs** (`project-photo.viewer.*`) are marked ⚠️ Stale: they
  predate the sectioned panel and now also lack the Rotation card. Restage
  from the running app (LL_VIEWER=1 + LL_SECTIONS=rotation).
- **Ken Burns collection export / time slicing** consume finished blend
  clips, so they inherit the level for free — but a collection built from
  a clip rendered BEFORE the project was levelled keeps the old geometry.
  Same rule as the grade; worth a line in the collection UI one day.
- **Keyframed rotation in mixed-resolution ramp shoots** (segment
  normalisation) levels every segment at the OPENING angle — the per-segment
  croppers have no whole-clip frame map to ease against — and the standalone
  pass then bakes colour only. Every other path eases per frame.
- **Adjust/Guided source-frame previews** level at the opening angle
  (`AdjustPreviewLevel`), not the moment's: the loaders know a clip time but
  not a source position. The bake is right; the preview is approximate under
  a travelling level.
- **Text-layer Angle shares the ±10° range** with the project control on
  purpose (one instrument). If a wider range is wanted for type, widen it
  on the overlay's slider only (`RotationSlider.range`).
- **Loupe / 1:1 patch under a level** is levelled by turning a larger
  source patch about the window centre (`PhotoGrader.renderDetail`);
  verified on Mac only at fit scale — pixel-peep a levelled DNG on device.

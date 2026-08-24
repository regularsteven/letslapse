# LetsLapse — open jobs

The queue of work that has been scoped but not done. One entry per job: what it
is, why it matters, and where the detail lives. A job leaves this list when it
ships, not when it is started.

Long jobs get their own document and are referenced from here. Short ones can
live inline.

---

## Open

### Framing-glitch hardening + Project Field Notes — device verification pending

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
**Raised:** 2026-08-24 · **Assessment done — job not started**

Steven wants the rich video configure screen (warp timeline, ramps, reframe,
canvas, fps card) for interval shoots, and the restricted variant phased out.
Assessment: no risk to video paths, but not a screen swap — stills sources
lack a time axis (basic interval shoots write no `frames.timestamps` at all),
the preview loader is movie-only, the stackers take no compiled schedule, and
the speed floor inverts for timelapse footage. Also corrects a premise: Photo
captures never reach this screen — the restricted branch serves Interval and
Scanner. Phasing in the doc; each UI phase is its own design-sync unit.

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

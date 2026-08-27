# LetsLapse — open jobs

The queue of work that has been scoped but not done. One entry per job: what it
is, why it matters, and where the detail lives. A job leaves this list when it
ships, not when it is started.

Long jobs get their own document and are referenced from here. Short ones can
live inline.

---

## Open

### Import a project from another device (local network)

**Detail:** [project-transfer-plan.md](project-transfer-plan.md) ·
**Raised:** 2026-08-27 · **Planned, not started** · *revised 2026-08-27 —
payload strategy, resume, AirDrop/USB*

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

Phased iOS-serve → Mac-import first, iOS import second, Mac serve last. UI is
unstarted and needs the design-first/app-first question asked before any of it
is drawn.

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
(12 Pro, veto at T+18.2).* Owed before this leaves the list: **(a)** SVG
mirrors after sign-off — settings.advanced + the watch controls page;
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

# LetsLapse — open jobs

The queue of work that has been scoped but not done. One entry per job: what it
is, why it matters, and where the detail lives. A job leaves this list when it
ships, not when it is started.

Long jobs get their own document and are referenced from here. Short ones can
live inline.

---

## Open

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

### iPad exposure pins at run start — the ramp never actuates

**Raised:** 2026-08-22 · **Not started** · **high** — silently ruins iPad
holy-grail shoots

Noticed by Steven as blown highlights when the sun came out on the M3, then
isolated with a four-device, matched-framing, 15-minute run (all arms Zone,
10 s, identical capture path: `bracketedRAW: true`, `bracketMaxFrames: 8`,
`responsiveCapture: false`, DNG, iOS/iPadOS 26.6).

**The ramp engine is not at fault.** Its own command record
(`frames.timestamps`) tracks the scene correctly on every device, and the
commanded ranges differ between families exactly as the ISO floors predict
(iPad ISO 16 vs iPhone 50 is ~1.6 stops, and 1/284 vs 1/840 is ~1.6 stops).

| arm | commanded | delivered | verdict |
|---|---|---|---|
| iPhone 16 Pro | 1/901 … 1/494 | 7 values, to **1/840** | actuating |
| iPhone 12 Pro | 1/826 … 1/451 | 30 values, to **1/831** | actuating |
| iPad Air M1 | 1/284 … 1/139 | **2** values | **STUCK** — 49 shorter *and* 31 longer ignored |
| iPad Air M3 | 1/309 … 1/136 | **1** value | **STUCK** — 51 shorter *and* 34 longer ignored |

Divergence: iPads 0.95 and 1.07 stops worst, with half of all measured windows
over 0.5 stop (15/29 and 18/30). The 16 Pro peaked at 0.53 on 1 window of 19.

**It is not a hardware floor.** Both iPads ignored *longer* commands as well,
which a device sitting at its minimum duration would happily accept.

**The tell — the pinned value changes between runs on the same device:**

| device | earlier run | matched-framing run |
|---|---|---|
| iPad M1 | 1/171 s | 1/248 s |
| iPad M3 | 1/222 s | 1/253 s |

So each iPad pins to whatever exposure was current **when the run started** and
then never moves — ISO included (a single value, 16, on both). That is the same
signature as the 2026-08-20 sunset, where all 2,247 iPad captures sat at the
pre-lock exposure.

Where to look: whether `setExposureModeCustom` is applied and *survives* on the
iPad bracketed-RAW path. The 2026-08-20 fix made ramped brackets carry the
device's live values via the range-proof `current` constants — faithful, and
therefore invisible, if the custom write never takes: the bracket then
reproduces the run's opening exposure forever. It was verified on iPhones
(≤0.14 stop) and evidently not on iPads.

Also worth fixing: `holyGrailHardwareLimits` (`CameraController.swift:5221`)
hands the ramp `format.minExposureDuration` as `minShutter`, so the engine
believes it has room it may not have; and sustained divergence should surface
on the capture screen rather than only in the log — the guard measured this
correctly for a whole shoot and nothing acted on it.

Diagnosis is automated: `tools/fleet_report.py` prints an **Actuation** section
per arm and classifies each actuating / FLOORED / STUCK; `shoot.py fleet`
collects `frames.timestamps`.

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

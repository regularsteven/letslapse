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

### iPad ramp commands are not actuated — shoots blow out as light rises

**Raised:** 2026-08-22 · **Not started** · **high** — silently ruins iPad
holy-grail shoots

Seen live on the M3 (project `6890F974`, "Stack 22. 8. at 17:16", Auto/Auto,
Zone) and reproduced the same afternoon on the M1 in a fleet smoke. Frames look
right at the start and blow out as the light rises.

**The ramp engine is innocent.** Its own record (`frames.timestamps`) shows it
tracking the sun correctly — M3 `smoothedEV` 12.45 → 13.70 → 12.11, a 1.59-stop
excursion — and commanding the shutter in both directions.

**The sensor did not follow, and the two iPads fail differently:**

| device | commanded | delivered | verdict |
|---|---|---|---|
| iPad Air M3 (iPad15,5) | 1/524 … 1/174 | **1** value, 1/222 | **STUCK** — 139 shorter *and* 36 longer commands ignored |
| iPad Air M1 (iPad13,16) | 1/387 … 1/170 | 2 values, ~1/171 | **FLOORED** — 51 shorter ignored, 0 longer |
| iPhone 16 Pro | — | 13 values, to 1/715 | actuating |
| iPhone 12 Pro | — | 21 values, to 1/796 | actuating |

The M1 looks like a minimum-exposure-duration limit around 1/171 s: it
lengthens when asked and never shortens past that. The M3 is worse than a
limit — it ignored 36 sustained *longer* commands (frames 138–185) as well, so
its exposure is simply pinned. Both are far longer than
`format.minExposureDuration`, which is what `holyGrailHardwareLimits`
(`CameraController.swift:5221`) hands the ramp as `minShutter` — so the engine
believes it has room it does not have and walks into a wall.

All four arms ran the identical capture path (`bracketedRAW: true`,
`bracketMaxFrames: 8`, `responsiveCapture: false`, DNG, iOS/iPadOS 26.6), so
this is not a configuration difference.

**Caveat not yet closed:** the iPhones were pointed at a different, less bright
scene, so it is proven they actuate two stops past where the iPads stop — not
that they would comply at *their* own floor. A matched-framing four-device
re-run settles it.

Where to look: `setExposureModeCustom` on the bracketed-RAW path, and whether
the true minimum latchable duration should be probed at session start (the
capability profiler already does this kind of measurement) rather than trusting
the format's claim. Consider surfacing sustained divergence on the capture
screen — the guard measured 102 of 135 windows over 0.5 stop and nothing acted
on it.

Diagnosis is automated now: `tools/fleet_report.py` prints an **Actuation**
section per arm (commanded range vs delivered distinct values) and classifies
each as actuating / FLOORED / STUCK, and `shoot.py fleet` collects
`frames.timestamps` so the evidence travels.

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

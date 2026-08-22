# Fleet baselines

One JSON per fleet session, written by `tools/fleet_report.py`. Each records
every arm of that session: device, strategy, the conditions it actually met,
what it decided, what it delivered, and the validity gate's verdict.

These files do two jobs, which is why the schema is boring and stable:

- **Instrument.** Read them to choose a strategy. Only arms with
  `"validity": "PASS"` belong in a comparison — an arm whose EV never
  traversed Zone's bands, or whose count the hardware chose, says nothing
  about its strategy however good its frames look.
- **Gate.** `fleet_report.py` diffs a new session against the newest earlier
  record for the same `device` + `strategy`, so a later change to the
  governor, the damper or the ramp cannot quietly make things worse.

## What a difference means

The diff separates two kinds of number, and only the first can fail a run:

| kind | fields | why |
|---|---|---|
| **code-sensitive** | `clampedWindows` · `shortfallWindows` · `failedWindows` · `starvedWindows` · `damperBypassJumps` | these move when the engine changes |
| **light-sensitive** | `evSpanStops` · `coverage*Percent` · `deliveredCounts` | these move when the weather changes |

A worsening code-sensitive number prints `REGRESSION`. A changed
light-sensitive number is reported as context and never fails anything.

## The validity gate

`gate` carries one verdict per criterion — `pass`, `fail`, or `unknown`.
`unknown` is never `pass`: logs written before the
`endReason`/`failedWindows` schema cannot certify V4, and saying so is the
point. `validity` is `FAIL` if anything failed, `INCOMPLETE` if anything is
unknown, `PASS` only when all six pass.

| | criterion | why |
|---|---|---|
| V1 | EV span ≥ 5 stops | Zone crosses its bands (13/10/7/4) only across a real traverse |
| V2 | no ceiling clamps | a clamped window is the hardware picking the count, not the strategy |
| V3 | ≥99% of windows within 0.5 stop of the command | the ramp actually actuated |
| V4 | no failed windows, ended as planned | a run that died is survivor-biased evidence |
| V5 | delivered == asked | a shortfall is a missed capture, not a decision |
| V6 | ≥3 distinct actuated counts | the strategy moved at all |

## Reading the history

Every existing capture log on disk as of 2026-08-22 **fails** this gate —
that is the finding the gate was built to make legible, not a defect. The two
sunset runs had `sceneEV` frozen at 0.00 stops by the bracketed-RAW bug; the
sunrise runs moved 0.40 and 0.81 stops with ISO pinned at its floor. In every
one of them each strategy emitted a single constant count for the whole shoot,
so "Zone 5 vs Latitude 7" is a fixed offset from one flat stretch of the
sigmoid rather than a behavioural difference.

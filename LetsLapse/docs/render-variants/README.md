# Render variants — the contract

Several rendering methodologies live in **one build**, switchable at runtime,
scored against each other by one command. This file is the rule book. The
scores are in [ledger.md](ledger.md); the definitions are in
[`Kit/Sources/LetsLapseKit/RenderVariant.swift`](../../Kit/Sources/LetsLapseKit/RenderVariant.swift).

## Why this exists

The obvious way to try a rendering idea is to change the renderer. Do that
twice and the first idea is gone: the code says what it does *now*, and nothing
anywhere says what the previous approach was worth or why it was dropped.

A git branch does not fix it. Two branches cannot be A/B-ed in a single run,
comparing them means a rebuild each time, and the measurements still live
nowhere.

So: every methodology stays alive in the build, and every result stays in git
next to the definition that produced it.

## The three rules

**1 · A variant is a frozen point.**
`RenderAxes` is composable — decode path × tone curves × tone response ×
exposure trim × white balance. A `RenderVariant` is one *named, fixed*
combination of those axes. The machinery is flexible so a new idea is a new
field rather than a new hand-written pipeline; the thing you test and record is
never ambiguous.

**2 · The registry is append-only.**
Once a variant has been measured and its numbers are in the ledger, its axes
are **never edited**. Improving `D1` means adding `D1.5`. This is the whole
mechanism — a variant id in the ledger means exactly one thing, forever.

`RenderVariantTests.testMeasuredVariantsHaveNotBeenRedefined` pins the axis
summary of every measured variant. Editing one fails the suite with a message
saying what it invalidated. That test is the enforcement; keep it current when
you add a variant.

**3 · Results live in git.**
`ledger.md` and `ledger.json` are regenerated, never hand-edited. A gain that
is not written down did not happen.

## Adding a variant

1. Append it to `RenderVariantRegistry.all`. Give it an id that has never been
   used, a one-line title, and — the field that matters most — a **hypothesis**
   saying what question it answers. A result without its hypothesis is a number
   nobody can act on later.
2. If it needs a new axis, add a field to `RenderAxes` with a sensible default,
   so every existing variant's `summary` is unchanged and their ledger rows
   stay true.
3. Re-run the bench, commit the regenerated ledger **in the same commit** as
   the variant.
4. Add its frozen summary to `testMeasuredVariantsHaveNotBeenRedefined`.

## Running it

```bash
(cd Kit && swift build --product lapse)
./tools/.venv/bin/python tools/render_bench.py --corpus <folder> --scale 0.5
```

A corpus is a folder of triples — `<name>.ARW`, `<name>.xmp` (Lightroom's
sidecar) and `<name>.jpg` (Lightroom's own export of that edit). The raws stay
**out of git**; only the ledger goes in, and it records which corpus, which
commit and which date produced each number.

Other entry points:

```bash
lapse variants                       # what this build defines, and what it can run
lapse variants --json                # the same, machine-readable
lapse lightroom <x.xmp> --render out.jpg --variant D1 --scale 0.5
```

## What the scores mean

Mean CIEDE2000 against Lightroom's own export of the same edit. Lower is
better: ~1 is just noticeable, 2–3 visible side by side, above 5 obvious.

Lightroom applies the sidecar's **crop and straighten** before exporting, so
its JPEG is smaller than the raw whenever anything was straightened — three of
`batch1`'s five. The harness applies the same rect and angle to our render
before scoring. Without that those files cannot be scored at all, and resizing
to fit would score a misalignment as a colour error.

## Two limits, stated rather than buried

- **The bench measures the whole-picture pipeline only.** Masked grades live in
  the app's compositor (`SceneAwareCompositor`), which the CLI cannot reach.
  That is where the structural gap sits anyway — measured 2026-09-07 at ΔE 6.5
  outside any mask — but a masked file's score is not the whole story. Closing
  this means giving the Kit the masked stage, which is tracked in
  `docs/TODO.md`.
- **The app does not yet honour the selected variant.** Today the switch is
  read by the CLI and the bench. Wiring `PhotoGrader` to
  `RenderVariantRegistry.current` — plus a Settings picker and an `LL_VARIANT`
  hook, the way `RawDecodePath` already does it — is the next step, and it is
  what makes the promise "test A against D in one build, in the app" literally
  true rather than nearly true.

## What the first run found

Full numbers in [ledger.md](ledger.md). The short version, on `batch1`:

| | mean ΔE | vs baseline |
|---|---|---|
| **A** baseline | 12.76 | — |
| **B** profile look curve | 12.78 | +0.02 — *nothing* |
| **C** Adobe's own DCP | 13.28 | +0.52 — *worse* |
| **D** shadows ×0.7 | 9.77 | −2.99 |
| **D1** D + look curve | 9.65 | −3.11 |
| **E** D1 + −0.47 EV | **7.78** | **−4.99** |

Three things worth keeping:

- **The slider calibration generalises.** `shadows ×0.7` was fitted on a single
  file before this apparatus existed, and it held across five — which is the
  question a one-file fit can never answer.
- **The profile look curve is worth nothing on its own** (+0.02) but −0.12 once
  the tone response is calibrated. It only becomes visible after the larger
  error is out of the way, which is an argument for keeping variants
  composable rather than hand-writing whole pipelines.
- **The dominant term was a systematic exposure offset.** Every variant, on
  every file, landed +0.27 to +0.87 stops bright. Nulling it was worth more
  than everything else combined — and nobody would have looked for it without
  the per-file numbers side by side.

The remaining ~7.8 is still far from the 2–3 that would read as matched, and
the earlier attribution work says it is structural: it varies with tone *and*
position, which is what a camera profile's tone-dependent hue map does and
what no global axis can imitate.

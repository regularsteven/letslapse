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

## In the app

Settings ▸ Render variant. The picker offers every variant this build can run
in full; a variant PINS the decode path, so the "Raw decode path" row below it
is disabled unless the baseline is selected — one switch cannot quietly
override another and still leave the ledger meaning anything.

`LL_VARIANT=<id>` stages one for a screenshot or a comparison run, the way
every other DEBUG hook works. Switching variants invalidates the render caches
(`PhotoGrade.cacheToken` carries the id), so the picture on screen is always
the variant that is selected.

The variant is applied in `PhotoGrade.recipe(at:)` — the one place a moment
becomes an engine recipe — so every path honours it by construction: editor
preview, thumbnails, blends and exports alike.

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

# Exploration: an UNREGISTERED point in the space, for sweeps. Deliberately
# cannot be recorded in the ledger under a name — only a registered variant
# can, which is what keeps an id meaning one thing forever. Promote a winner
# by adding it to RenderVariantRegistry.all.
lapse lightroom <x.xmp> --render out.jpg --scale 0.25 \
      --axes "curves=imageAndLook,shadows=0.7,exposure=-0.47"
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

- **The bench renders the masked grades, except AI skies.** Since the evening
  of 2026-09-07 the masked stage is the Kit's `MaskedGradeStage` — the same
  code the editor's preview and a stills export run — and `lapse lightroom
  --render` applies every parametric mask. What it cannot draw is an AI sky
  mask: that needs the app's segmentation model. Such a file is rendered
  without that one edit, the CLI says so (`masks=applied/total`), and the
  ledger marks the file †. Three of the twenty carry one.
- **Curve-honouring variants are BENCH ONLY.** The tone curves come from the
  sidecar, and the app grades a *project*, which carries no curve — so `B`,
  `D1` and `E` cannot be run in full in the editor. Settings lists them,
  disabled, under "Bench only" with the reason rather than hiding them: they
  are in the ledger and somebody will come looking. Giving `PhotoGrade` a
  curve of its own would close it (`docs/TODO.md`).

Attribution flags on the render, for splitting a residual: `--no-masks`,
`--flip-masks` (every parametric mask on the other side — the check that
settled the importer's inside/outside rule), `--no-dehaze`, `--no-hsl`.

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

The remaining ~7.8 is still far from the 2–3 that would read as matched.

## Calibration cal1 — and why it lives in the IMPORT (2026-09-07)

The tone correction the bench found (−0.47 EV, shadows ×0.7) moved out of the
render axes and into `LightroomImport.calibration`.

**Why not the renderer.** It corrects one renderer against another, and the
only place that comparison means anything is an imported Lightroom edit.
Putting it in the engine would have darkened every LetsLapse project ever shot
by half a stop to match a program the photographer may not own. Our native
look is our own.

**What that cost.** Variants `D`, `D1`, `E`, `F`, `F1`, `F2` were measured
before the move and their axes would now apply the correction a *second* time.
They are **retired**, not deleted or redefined: the definitions and their old
numbers stand as a record, and the bench stops running them. That is what
`RenderVariant.retired` is for — the append-only rule surviving a change made
*underneath* a variant.

## Validating cal1 on a wider corpus

15 files across three batches, two cameras, mixed sidecar and embedded
settings. Corpus mean with cal1 applied on import:

| variant | mean ΔE |
|---|---|
| **G** — look curve + dehaze ×2 | **11.02** |
| B — look curve | 11.51 |
| A — baseline | 11.61 |
| C — Adobe DCP | 11.83 |

cal1 generalises to the batch1 files it was fitted on (they now sit at 5.1–10.5
under plain `A`, where uncalibrated `A` had them at 9.2–16.8) and does no harm
elsewhere. But **the wider corpus is a much harder problem than batch1**: the
mean is 11.6, not 7.5, and it is dominated by a few files carrying edits we
have no controls for at all.

The three worst are the diagnosis, not noise:

| file | A | what it asks for |
|---|---|---|
| `_WEB5777` | 26.56 | Dehaze 53, **17 HSL sliders**, custom tone curve, post-crop vignette −43 |
| `_WEB5765` | 17.12 | Dehaze 89, Grain 40, post-crop vignette −32, contrast +37 |
| `_WEB5162` | 14.05 | — |

`G` takes `_WEB5777` from 26.56 to 20.05 and `_WEB5179` from 14.02 to 8.71,
both on dehaze — but *loses* on `_WEB5765` (17.12 → 21.81) and `_WEB5782`
(10.24 → 13.22), where dehaze at ×2 overshoots on an already heavily-pushed
edit. **The ×2 scale fitted on one file does not generalise.** It wants to be
a function of the sidecar's own Dehaze value, not a constant.

## Reading settings that are not in a sidecar

A DNG that has been through Enhance or Denoise comes back with its settings
**inside the file** and no `.xmp` at all — three of these fifteen. They are
read from TIFF tag 700 (`LightroomSidecar.embeddedXMP`), parsed out of the
directory rather than by scanning for `<x:xmpmeta`, which would happily find
the packet in an embedded preview instead of the real one. The bench discovers
by RAW rather than by sidecar, so those files are no longer skipped in silence.

## What the residual is made of## What the residual is made of, and what will not fix it

Measured 2026-09-07 on variant E, decomposing ΔE2000 into its three parts:

| | mean |
|---|---|
| lightness ΔL* | 6.07 |
| chroma ΔC* | 6.18 |
| hue ΔH* | **3.18** |

Three negative results, each worth more than a guess:

- **More slider calibration is worthless.** An 18-point sweep of every tone
  axis we have — highlights ×{1.0, 0.85, 0.7} × shadows ×{0.7, 0.55, 0.4} ×
  exposure {−0.47, −0.65} — found a best of ΔE 7.624 against E's 7.705. A
  gain of 0.08 across the whole space. That seam is mined out; use `--axes`
  to re-check it if the corpus changes, but do not expect anything.
- **The chroma error is not a global response.** The single best global chroma
  scale per file buys 0.32 mean, and the scales it wants are wildly
  inconsistent — ×0.70 on one file, ×1.35 on another. Whatever is wrong is
  per-image and, on the evidence below, per-REGION.
- **Hue is the smallest term.** Which makes HSL controls, and the profile's
  hue map, a poorer bet than the earlier attribution work assumed. Only one of
  the five files touches HSL at all.

**The strongest signal in the data is `_DSC6372`.** Our mean chroma is 5.25
against Lightroom's 13.34 — we are 2.5× under-saturated — and it is the
worst-scoring file at ΔE 10.69. It is also the file with **Dehaze 45**, by far
the heaviest in the corpus. Dehaze adds local contrast and saturation, and we
have no equivalent at all. That a global chroma boost recovers only 0.41 of
its 10.69 is the tell: the deficit is localised, exactly as a haze operation
would be.

So the next real gains are in operations that vary WITHIN the image — not in
more global scalars.

## Dehaze — the first spatially varying operation (2026-09-07)

Built as a dark-channel prior (`Kit/Sources/LetsLapseKit/Dehaze.swift`) and
benched before it goes anywhere near the Metal kernel, which is the order this
system exists to make possible.

It did exactly what the hypothesis said it would, and nothing else:

| file | sidecar Dehaze | E | F (dehaze ×1) | F2 (dehaze ×2) |
|---|---|---|---|---|
| `_DSC6372` | **45** | 10.69 | 9.86 | **9.12** |
| `_DSC6498` | 7 | 8.85 | 8.85 | 8.85 |
| `_DSC6507` | 4 | 4.49 | 4.49 | 4.49 |
| `_DSC6509` | 0 | 5.23 | 5.23 | 5.23 |
| `_DSC6512` | 0 | 9.61 | 9.61 | 9.61 |
| **corpus** | | 7.78 | 7.61 | **7.46** |

The files that ask for no dehaze are bit-identical, which is the check that
matters most: an operation that "improves" a picture nobody asked to change is
a bug, not a win.

**Our dehaze is about half Adobe's strength at the same nominal value.** A
sweep on the heavy file put the optimum at ×2.0: chroma climbed 5.19 → 11.27
against Lightroom's 13.31 and ΔE bottomed at 9.12, while ×3.0 overshot to
C* 18.62 and ΔE 13.91. That is precisely why `dehazeScale` is a scale and not
a flag — two different algorithms reaching for the same effect have no reason
to agree on what 45 means.

Corpus mean 12.76 → **7.46**, a 42% reduction. Most of that is the tone work;
dehaze adds 0.32 across the corpus but **1.57 on the one file that needed it**,
which is the honest way to read a per-region operation on a five-file corpus.

## Pass two (2026-09-07, evening) — the bench had two bugs, and the masks are in

Twenty files now (`batch4` added five). Everything below was measured before
it was believed, in this order.

**The straighten sign was inverted.** A positive `CropAngle` turns the
picture anticlockwise on the way out of Lightroom; the harness rotated our
render the other way. Nothing caught it because the scores stayed plausible —
just 0.6 to 1.8 ΔE too high on every straightened file. Found by sweeping the
applied angle: `_DSC6509` (+0.797°) bottoms out at −0.64° applied,
`_WEB5223` (+0.680°) at −0.75°, and on all three files tried, NO rotation beat
the sign as written. Ten of the twenty files are straightened, so this alone
moves the corpus mean. The sweep is in `apply_crop`'s comment; re-run it
before touching that line.

**Lightroom's mask geometry is in the SENSOR frame**, exactly like its crop
rect, which the first pass had already found. `_WEB5253` is a portrait shot
(orientation 8) with one linear gradient. Read through the display frame the
gradient runs left–right and correlates +0.03 with the lightness Lightroom
added; read through the sensor frame it runs top–bottom and correlates +0.34,
with the FULL end +8.3 L* and the ZERO end +1.8. The importer now turns every
parametric mask by the file's orientation (`LightroomSidecar.orientation`,
`MaskShape.fromSensorFrame`): a quarter turn maps the points and swaps the two
radii, and the rotation angle stays, because an ellipse with its radii
exchanged is that ellipse turned a quarter. Full render, `_WEB5253`: 8.93
without the mask, 7.43 with it turned.

**The inferred inside/outside rule is right.** `_DSC6372`'s radial (Flipped
true, MaskInverted false, LocalTemperature +0.6, nothing else) is the one
radial in the corpus. On the unmasked render, Lightroom's added warmth (Δb*)
correlates +0.71 with the ellipse's inside coverage — +15 b* inside, −3.5
outside. Then the full renders, through the Kit's own masked stage:

| `_DSC6372` | ΔE |
|---|---|
| masks as imported (inside) | **9.56** |
| no masks | 10.49 |
| `--flip-masks` (outside) | 12.75 |

**The masked stage is the Kit's now.** `DisplayGrade` is the app's legacy
`PhotoGrader.adjust` chain moved verbatim; `MaskedGradeStage` clamps a grade
to a mask's travel and blends it through a selection; `MaskShapeRenderer`
moved out of the app. The editor's preview, a stills export and `lapse
lightroom --render` run one implementation, and the ledger's rows are whole
renders. The exception is an AI sky mask (three files): the CLI has no
segmenter, says so on its summary line, and the ledger marks the file †.

**HSL, built as the plainest reading of the panel and worth more than
anything since cal1.** Eight bands at the panel's own hue angles (red 0°,
orange 30°, yellow 60°, green 120°, aqua 180°, blue 240°, purple 275°,
magenta 315°), triangular weights between neighbours, a hue turn of one band
at ±1, chroma ×0…2, lightness toward black or white weighted by the pixel's
own chroma — all on gamma-2.2 encoded values after the engine. Nine files use
the panel; on the heavy ones, with everything else as it was:

| file | HSL sliders | without | with HSL |
|---|---|---|---|
| `_WEB5777` | 17 | 26.66 | **19.86** |
| `_WEB5179` | 10 | 13.39 | **11.42** |
| `_WEB5782` | 11 | 11.94 | **10.37** |
| `_WEB5929` | 13 | 8.70 | **7.80** |
| `_WEB5182` | 23 | 11.17 | **10.51** |
| `_WEB5320` | 6 | 9.96 | 10.29 |
| `_DSC6498` | 2 | 7.92 | 7.87 |

The first pass's "HSL is a poor bet" is now measured as well as retracted.
The model is deliberately the first reasonable one; Adobe's band shapes and
travel are unpublished, and the bench is what will say whether a second
reading is worth having.

**Dehaze became a control, and calibrating it took a second metric.** The
per-file strength sweep is confounded with our per-file brightness error: our
dehaze darkens, we land anywhere from −1.25 to +1.12 stops against Lightroom
per file, and on a file we render bright the raw score rewards any darkening
for the wrong reason (`_WEB5777` "wanted" ×3 dehaze at +1.1 stops bright;
matched for exposure it wants none). So `score()` now also reports an
**exposure-nulled ΔE** — our linear luminance scaled to the reference's mean,
then re-encoded — which is the number to calibrate a colour or local-contrast
control against, and never the ledger's number. Two more things fell out:

- **Dehaze and HSL interact.** The three files that reject any dehaze at all
  (`_WEB5777`, `_WEB5782`, `_WEB5929`) are the three that pull their skies'
  saturation to −100 through HSL. Dehaze adds saturation exactly where they
  take it away, so it was calibrated with the panel ON.
- **The optimum is not a clean function of the slider.** Files at 41–54 want
  an amount near 1.0; `_WEB5765` at 89 wants 0.9 and is wrecked past 1.5 (the
  transmission floors and the recovery runs away); files at 10 want anything
  from nothing to 0.4. A saturating response — steep from zero, flat from
  about 30 up — is the shape the data supports, and `DehazeCalibration`
  (`dh1`) is that fit; the numbers are in the next section. The ×2 constant
  the first pass found is retired with variant `G`.

`GradeRecipe.dehaze` and `GradeRecipe.hsl` render after the Metal engine in
`EnginePostPasses`, through the same function on every path: the editor's
still render, a stills blend (the export bake's frame hook), the CLI, and the
video chain by way of `DisplayGrade`. Neither has a slider yet — the import
writes them — and that is UI work with its design-sync question still to ask.

### The numbers, and what each step bought

Twenty files, variant `A` — the shipping renderer, whose axes did not change —
with each piece added in turn (`--render-flags` on the bench turns them off
for an attribution run; the committed ledger never carries flags):

| step | mean ΔE | Δ | exposure-nulled mean |
|---|---|---|---|
| before this pass (commit `cc42f78`) | 11.30 | — | — |
| the straighten sign fixed | 10.84 | −0.46 | 9.29 |
| + the parametric masks | 10.72 | −0.12 | 9.19 |
| + dehaze `dh1` (HSL off) | 10.38 | −0.34 | 9.02 |
| + HSL (dehaze off) | 10.08 | −0.64 | 8.70 |
| **+ both — the ledger's `A`** | **9.86** | **−1.44** | **8.53** |

`B` (the look curve) is the best row at **9.71**; retired `G` sat at 10.85
on these files. Per file, nineteen of twenty improved under `A`, by 0.02 to
6.07 (`_WEB5777`, 26.56 → 20.49); one got worse.

**What dehaze and HSL are each worth, per file, with the other on** (the
files where either moved the score by more than 0.05):

| file | dehaze | HSL |
|---|---|---|
| `_WEB5179` | −2.42 | −2.15 |
| `_WEB5777` | +0.40 | −3.47 |
| `20240918_191653` | −0.06 | −2.09 |
| `_WEB5929` | −0.44 | −1.40 |
| `_WEB5196` | +0.14 | −0.99 |
| `_WEB5782` | +0.47 | −0.86 |
| `_WEB5162` | −0.82 | — |
| `_DSC6372` | −0.71 | — |
| `_WEB5182` | +0.08 | −0.64 |
| `_WEB5765` | −0.44 | — |
| `_WEB5320` | −0.25 | +0.35 |
| `_WEB5167` | −0.11 | **+0.84** |

Two things to take from that table rather than the mean:

- **Dehaze at the slider's number still loses on the two heavily-curved
  files** (`_WEB5777`, `_WEB5782`, both with a custom tone curve and the
  heaviest HSL desaturation). `dh1` was chosen as the response with the
  smallest worst case, not the one with no worst case; there is none.
- **`_WEB5167` is the pass's one regression, and it is the HSL panel's.**
  Six modest sliders (Orange saturation −32, Red −11, small hue and luminance
  moves) cost 0.84. `_WEB5320`'s six cost 0.35. Both are orange-band edits,
  which makes the orange band's response — its centre, its width, or a chroma
  scale that should not be linear — the first thing to calibrate about the
  panel, by the same per-file sweep dehaze got.

**What is left is mostly brightness, and it is per file.** Matched for
exposure, `A` would score 8.53, not 9.86: 1.33 of the mean is a flat gain
per file, and it is a different gain on every file — `_WEB5777` renders
+1.42 stops bright, `_WEB5765` −0.75 dark, and the mean absolute offset is
0.37 stops after `cal1` has nulled the average. That is not another constant;
it tracks the edits we do not model on each file (a custom tone curve on the
three worst offenders, Contrast +37 on `_WEB5765`, the post-crop vignette on
eight). The next pass's largest single target is that per-file tone
response, and the first thing to measure is whether honouring the image's
own point curve inside the app's grade — a control, not a bench axis —
closes it.

The dehaze fit itself, for the record (sixteen files that use it, HSL and
masks on, exposure-nulled mean): no dehaze 8.60 · ×1 8.37 · best saturating
curve 8.36 · ×2 8.77. The per-file optimum runs from 0 to 1.1 at the same
slider value. Data in the session's `dehaze_sweep3.json`; the sweep script is
three lines around `lapse lightroom --no-dehaze --axes dehaze=<k>`.

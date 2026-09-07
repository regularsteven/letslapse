# Lightroom parity — handover

**Goal:** render a raw file so it looks like Lightroom's own export of the same
edit. We read Lightroom's settings, map them onto ours, render, and score the
result against Lightroom's JPEG.

**Where it stands (2026-09-07):** mean CIEDE2000 **11.0** across 15 files, from
a baseline of 11.6. On the five-file corpus this started with, 12.76 → 7.46.
Visually matched would be ΔE 2–3. We are not close, and the reason is now
well characterised rather than mysterious.

This document is for whoever picks it up next. It is written to be read once,
top to bottom, before touching anything.

---

## 1 · Run everything in five minutes

```bash
cd LetsLapse/Kit && swift build --product lapse && cd ..

# What one file asks for, and what we can do with it
./Kit/.build/debug/lapse lightroom "<path>/batch1/_WEX3825.xmp"
./Kit/.build/debug/lapse lightroom "<path>/batch3/_WEB5167-Enhanced-NR.dng"

# The rendering methodologies this build carries
./Kit/.build/debug/lapse variants

# Score them all against Lightroom's exports and rewrite the ledger
./tools/.venv/bin/python tools/render_bench.py --corpus <folder> --scale 0.4

# One file, one unregistered point in the space (for sweeps)
./Kit/.build/debug/lapse lightroom <x.xmp> --render out.jpg --scale 0.25 \
    --axes "curves=imageAndLook,dehaze=2.0"
```

The corpora are on the Desktop: `Lightroom Exports/Lightroom CC/batch{1,2,3}`.
Each holds triples — raw, `.xmp` (sometimes), and Lightroom's own JPEG export.
Pool them with symlinks into one folder to bench all 15 at once.

**Read `docs/render-variants/README.md` next.** It is the rule book for the
experiment system and it is short.

---

## 2 · The method, and why it is shaped this way

The hard problem here is not rendering. It is **not losing what you learned.**
Change the renderer twice and the first idea is gone: the code says what it
does now, and nothing says what the previous approach was worth. Git branches
do not fix it — two branches cannot be A/B-ed in one run, and the measurements
still live nowhere.

So the working method is:

1. **Every methodology stays alive in one build.** `RenderAxes` is composable
   (decode path × tone curves × tone response × exposure trim × dehaze);
   a `RenderVariant` is one *named, frozen* combination.
2. **The registry is append-only.** A measured variant is never edited.
   Improving `D1` means adding `D1.5`. `RenderVariantTests.
   testMeasuredVariantsHaveNotBeenRedefined` pins every measured variant's
   axes and fails loudly if one changes.
3. **A variant whose meaning changed underneath it is RETIRED, not edited.**
   When the tone calibration moved into the import, six variants would have
   double-applied it. They carry a `retired` reason; the bench skips them;
   their old numbers stand as a record.
4. **Results live in git**, regenerated (`docs/render-variants/ledger.md`),
   never hand-edited, stamped with corpus, commit and date.
5. **Exploration is separate from record.** `--axes` renders an unregistered
   point for sweeps. Only a registered variant can appear in the ledger, so an
   id always means exactly one thing.
6. **Measure before building.** Dehaze was implemented as a post-pass and
   benched before anything went near the Metal kernel.

That last one is the habit worth keeping. Three of my confident predictions
were wrong and the bench caught all three within minutes (§6).

---

## 3 · Map of the code

| what | where |
|---|---|
| Parse a Lightroom sidecar (facts) | `Kit/…/LightroomSidecar.swift` |
| XMP embedded in a DNG (TIFF tag 700) | same file, `embeddedXMP(in:)` |
| Map settings → our grade (judgement) | `Kit/…/LightroomImport.swift` |
| The fitted correction, `cal1` | `LightroomImport.calibration` |
| Variants, axes, registry, selection | `Kit/…/RenderVariant.swift` |
| Point tone curve (monotone cubic) | `Kit/…/ToneCurve.swift` |
| Dark-channel dehaze | `Kit/…/Dehaze.swift` |
| Parametric mask geometry | `Kit/…/MaskShape.swift` |
| CLI: report, render, variants | `Kit/Sources/lapse/main.swift` |
| Bench + ledger writer | `tools/render_bench.py` |
| ΔE2000 / tone / region compare | `tools/lightroom_compare.py` |
| App: apply an import | `App/Overlay/LightroomSettingsImport.swift` |
| App: the import report sheet | `App/Overlay/LightroomReportSheet.swift` |
| App: masked grades composite | `App/Overlay/SceneAwareCompositor.swift` |
| Rule book | `docs/render-variants/README.md` |
| Scores | `docs/render-variants/ledger.md` |

**Parsing and mapping are deliberately separate.** Parsing is a fact — the file
says Exposure2012 is +0.29. Mapping is a judgement — our Exposure is the same
unit so it transfers, our Clarity is a different curve so it approximates, and
we have no Dehaze control so it is reported as lost. Keeping them apart is what
lets the losses be *reported* instead of silently absorbed.

---

## 4 · What the corpus actually asks for

15 files, three batches, two cameras. This table is the most actionable thing
in this document.

| control | files using it | do we support it? |
|---|---|---|
| **Dehaze** | **13 / 15** | bench axis only — no project control |
| **HSL (24 sliders)** | **9 / 15** | **no** |
| **Crop / straighten** | **9 / 15** | **no** — the import drops it |
| **Post-crop vignette** | **8 / 15** | **no** (global vignette exists; post-crop does not) |
| Tone curve | 5 / 15 | bench axis only — no project control |
| Masks | 4 / 15 | **yes** — radial, linear, sky |
| Colour grading | 2 / 15 | no |
| Grain | 2 / 15 | no |
| Lens profile | 1 / 15 | no |

Regenerate it:

```bash
./tools/.venv/bin/python - <<'EOF'
import os, re
CORPUS = "/tmp/allbatches"   # a folder of raws + .xmp + .jpg
HUES = ["Red","Orange","Yellow","Green","Aqua","Blue","Purple","Magenta"]
def xmp(stem):
    for e in (".xmp", ".XMP"):
        p = os.path.join(CORPUS, stem + e)
        if os.path.exists(p): return open(p, encoding="utf-8", errors="replace").read()
    for e in (".dng", ".DNG", ".ARW"):
        p = os.path.join(CORPUS, stem + e)
        if os.path.exists(p):
            b = open(p, "rb").read(); i, j = b.find(b"<x:xmpmeta"), b.find(b"</x:xmpmeta>")
            if i >= 0 < j: return b[i:j+12].decode("utf-8", "replace")
    return ""
def num(t, k):
    m = re.search(r'crs:' + k + r'="([^"]*)"', t)
    try: return float(m.group(1).replace("+", "")) if m else 0.0
    except ValueError: return 0.0
stems = sorted({os.path.splitext(f)[0] for f in os.listdir(CORPUS)
                if os.path.splitext(f)[1].lower() in (".arw", ".dng")})
tally = {}
for s in stems:
    t = xmp(s)
    if not t: continue
    tally[s] = {
        "Dehaze": num(t, "Dehaze"),
        "HSL": sum(1 for ax in ("Hue","Saturation","Luminance") for h in HUES
                   if num(t, f"{ax}Adjustment{h}")),
        "Curve": 0 if 'ToneCurveName2012="Linear"' in t else 1,
        "PostCropVig": num(t, "PostCropVignetteAmount"),
        "Grain": num(t, "GrainAmount"),
        "Crop": 1 if 'HasCrop="True"' in t else 0,
        "Masks": t.count('crs:What="Correction"'),
    }
for key in ("Dehaze","HSL","Curve","PostCropVig","Grain","Crop","Masks"):
    print(f"{key:14s} {sum(1 for r in tally.values() if r[key]):2d}/{len(tally)}")
EOF
```

---

## 5 · Assumptions I made — check these first

Each of these is a real decision that could be wrong. They are ordered by how
much damage a wrong one does.

1. **`Flipped` XOR `MaskInverted` decides which side of a radial gets the
   grade.** `LightroomImport.appliesOutside`. **Inferred, not documented.**
   If it is backwards the grade lands on precisely the wrong pixels. One
   reference render settles it; it is one line to flip. *Nobody has verified
   this against a rendered mask.*
2. **`cal1` (−0.47 EV, shadows ×0.7) is fitted on five frames from one camera**
   (Sony A7 IV, batch1). It generalised to the other ten and did no harm, but
   it is a constant standing in for a difference between two tone curves. It
   almost certainly should be a *function* of the sidecar's values, not a
   constant.
3. **Masked grades run display-referred**, through `PhotoGrader.adjust`, not
   the Metal tone engine. Deliberate: it is the only stage the preview and a
   stills-blend export share, so it guarantees they agree. The cost is that a
   masked grade cannot recover a highlight the whole-picture grade clipped.
   Documented at length in `SceneAwareCompositor.composited`.
4. **An AI sky mask is substituted with our own segmentation.** The edit
   transfers exactly; the boundary is ours. For a timelapse this is arguably
   better (ours re-segments per seam) but it is not what Lightroom drew.
5. **Named white-balance presets map to conventional Kelvins** ("Cloudy" =
   6500 K). Lightroom resolves them per camera from the profile; we cannot.
   Approximate by construction.
6. **The tone curve is applied at the end, on display-referred pixels.**
   Lightroom applies its point curve inside its own pipeline. Ours is a
   `CIColorCurves` pass after the engine. Close in spirit, not identical in
   placement.
7. **Dehaze runs on display-referred pixels too**, after the engine. The
   dark-channel prior assumes something closer to scene-linear.

---

## 6 · Lessons learnt, including three wrong calls

**I predicted the profile's tone curve was the dominant error. It is worth
0.25 ΔE.** Measured on batch1: 9.13 → 8.89. Real but small.

**I predicted the camera profile's hue map was the structural culprit.** Then
decomposed the residual: lightness 6.07, chroma 6.18, **hue 3.18**. Hue is the
*smallest* term. The DCP path (variant C) measured *worse* than the default.

**I told you HSL was a poor bet.** That was true of batch1, where 1 file in 5
touched it. On the full corpus it is **9 of 15**. Do not carry my earlier
recommendation forward — it was drawn from too small a sample. This is the
clearest single lesson: *batch1 was an easy, unrepresentative corpus.*

Other things worth knowing:

- **The biggest single win was one nobody predicted** — a systematic +0.27 to
  +0.87 stop brightness offset on every file and every variant. Nulling it beat
  everything else combined. It was visible only because the bench printed
  per-file exposure offsets side by side.
- **Slider calibration is exhausted.** An 18-point sweep over highlights ×
  shadows × exposure moved the best result by 0.08. Do not re-mine that seam.
- **The chroma error is not a global response.** Best per-file chroma scale
  buys 0.32 mean and wants ×0.70 on one file and ×1.35 on another. It is
  per-image and per-region.
- **The ×2 dehaze scale does not generalise.** Wins big on `_WEB5777`
  (26.6 → 20.1) and `_WEB5179` (14.0 → 8.7); loses on `_WEB5765`
  (17.1 → 21.8) and `_WEB5782` (10.2 → 13.2). It overshoots on already
  heavily-pushed edits.
- **Two harness bugs nearly poisoned the ledger**, both silent: orientation was
  assumed rather than matched (my first "fix" rotated upright frames into
  landscape), and the crop rect is in the SENSOR frame while our decoder
  returns frames already oriented. Both are fixed and now self-checking. **Any
  new geometry handling should fail loudly rather than resize to fit.**
- **A null result is a result.** Dehaze leaves files that ask for none
  bit-identical. That check matters more than the win.

---

## 7 · The AI mask payload — do not re-analyse this

Lightroom ships its AI masks' bitmaps in the sidecar as
`crs:Table_<MaskDigest>` (223 KB of `_WEX3825`'s 242 KB). It was analysed and
the conclusion is negative:

- 229,183 chars, **exactly 85 distinct** — Ascii85's alphabet with the 8
  XML-unsafe characters (`"` `&` `,` `;` `<` `>` `\` `_`) replaced by `v`–`}`.
- **Not Ascii85-of-bytes.** Under every alphabet order, digit direction and
  offset tried, ~3.3% of 5-char groups exceed 2³²−1 — exactly the fraction
  expected of *uniformly random* base-85 digits, (85⁵−2³²)/85⁵ = 3.2%. A real
  encoder emits none.
- Entropy **6.408 bits/char against a 6.409 maximum**, flat throughout: the
  data is already compressed before encoding.

So it is a whole-block base-85 radix conversion of a compressed stream.
Decoding needs Adobe's container as well as their base-85 variant — open-ended,
and brittle even if it lands. The payload is parsed into
`LightroomSidecar.maskTables` if anybody wants to try.

---

## 8 · Open questions

1. **Is `appliesOutside` right?** (§5.1) Cheapest, highest-consequence check
   available. Render a file with a radial mask and compare the masked region to
   Lightroom's.
2. **Should the residual be scored on masked renders?** The bench renders the
   whole-picture grade only; the masked stage lives in the app's compositor and
   the CLI cannot reach it. Four of fifteen files carry masks, so their scores
   are incomplete. Moving the masked stage into the Kit (it is pure Core Image,
   no app dependencies) would fix the bench *and* put preview, export and bench
   on one implementation.
3. **Is ΔE2000 the right target at all?** It is a *perceptual difference*
   metric, and we are chasing a *look*. A render that is 2 ΔE away uniformly
   may look better than one that is 1 ΔE away with the error concentrated in
   skies. Consider scoring the tone-band table and a per-region max alongside
   the mean.
4. **Does `cal1` hold on a third camera?** Both cameras so far are Sony. A
   Canon or Fuji file would say whether it is a renderer property or a sensor
   one.
5. **What does Lightroom do that has no slider?** Its default rendering
   includes a baseline tone curve and a per-camera profile we approximate with
   Apple's. That is probably where the irreducible residual lives.

---

## 9 · Recommended approach for the next pass

Ordered by expected value. The first two are cheap and unblock measurement;
the rest are the actual gains.

**1 · Verify the mask inversion assumption.** One render. If it is wrong,
everything measured on the four masked files is off.

**2 · Move the masked-grade stage into the Kit so the bench can score whole
renders.** Until this happens, four of fifteen scores are partial and any
mask-related conclusion is unsafe.

**3 · Build the three controls the corpus actually asks for**, in this order —
they are 13/15, 9/15 and 9/15 of the corpus and we support none of them as
project controls:

- **Dehaze as a real control** on `PhotoAdjustments`, so the import can carry
  it rather than it being a bench axis. The algorithm exists
  (`Dehaze.swift`) and works; it needs a field, a slider, and a strength
  mapping that is a *function* of the sidecar value rather than a constant ×2.
- **HSL** — eight hues × three axes. Nine files use it, `_WEB5777` uses 17
  sliders, and it is the largest unbuilt control by usage. My earlier
  "HSL is a poor bet" was drawn from batch1 alone; ignore it.
- **Crop and straighten on import.** Nine files are cropped and we drop it
  entirely, so an imported project is not even the same framing. This is a
  correctness gap as much as a parity one, and probably the most visible to a
  real user.

**4 · Then re-fit `cal1` per-file rather than as a constant**, once those
controls exist — the current constant is compensating partly for things that
will then be modelled properly.

**5 · Only then consider the profile.** The DCP path measured worse, hue is
the smallest residual term, and Adobe's profiles are not ours to redistribute.
This is the expensive, low-yield end.

**How to work:** add a variant per idea, keep the registry append-only, re-run
the bench on all 15, commit the regenerated ledger in the same commit, and
write the hypothesis down *before* the number. If a change makes something
worse, that row is as valuable as a win — leave it in.

---

## 10 · Traps

- **`--scale` matters.** The bench renders at reduced scale for speed; scores
  shift slightly with it. Compare like with like, and the ledger records it.
- **Sidecar before embedded XMP.** When both exist the sidecar is newer.
- **The bench discovers by RAW, not by sidecar** — three DNGs carry their
  settings internally and were being skipped in silence.
- **Our decoder applies EXIF orientation; Lightroom's crop rect does not.**
  See `sensor_rect_for`.
- **Variant selection invalidates render caches** via `PhotoGrade.cacheToken`.
  If you add an axis that changes pixels, make sure it reaches that token.
- **Curve- and dehaze-honouring variants are bench-only** (`needsSidecar`) —
  a project carries no curve, so the app cannot run them in full. Settings
  lists them disabled with the reason.
- **The corpus lives outside git.** Only the ledger is committed.

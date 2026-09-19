# Shape-mation alignment — synthetic runs

> Pooled, mixed-scene run (2026-09-19, later — every scene, sky, angle, size and position at once): `mixed-scenes-report.md`.

## Addendum, 2026-09-19 evening — the kit is the corpus

Everything from "first synthetic run" down was measured on a **placeholder
tram** the first agent drew itself (`tools/shapesynth/parts/subjects.py`: a
1.0 × 0.65 body rectangle with a pantograph, flat sky and ground, one affine
placement) because it never read Steven's scene kit at `docs/design/kit`
(b46fc48). That kit — `build.js` composing `recipes.json` into 60
compositions with the Prague T3 tram at five views, six skies, five scenes,
and the face polygon, bbox, margins and 3×3 cells on every root — is the
generator from now on; the placeholder parts and `compose.py` are deleted,
`tools/shapesynth/kit.py` reads the kit and `shapesynth.py generate`
rasterises it at 2× (`README.md` there). The numbers below still hold as a
statement about the pipeline (an exact plan lands each dial 1 : 1 in its own
residual whatever is drawn), but they are not the kit's numbers. These are:

```
cd Kit && swift build -c release --product lapse && cd ..                                   # 38 s
tools/.venv/bin/python tools/shapesynth/shapesynth.py selftest                               # 916 passed, 0 failed
tools/.venv/bin/python tools/shapesynth/shapesynth.py generate --kit docs/design/kit --out tools/shapesynth/work/kit --sequence all --scale 2
tools/.venv/bin/python tools/shapesynth/shapesynth.py generate --kit docs/design/kit --out tools/shapesynth/work/kit --sequence city.clear.approach --scale 2 --sigma-centre 0.05 --seed 5 --set-suffix=-c05
Kit/.build/release/lapse shapemation stage tools/shapesynth/work/kit --out tools/shapesynth/work/kit-projects --project      # 72 scenes, every one `rectangle`
Kit/.build/release/lapse shapemation score tools/shapesynth/work/kit-projects/<set>/* --family rectangle
```

Re-scored kit sets, truth = the face bbox from the manifest, register = the
truth (σ = 0) staged through the Kit factories:

```
city.clear.approach       (12, left view, 3600×2400)    SHAPEMATION SCORE: placed 12 · dropped 0 · centre median 0.000 p90 0.000 max 0.000 · scale median 0.000 · rotation median 0.0° · corners rms 0.0 px
oldtown.golden.approach   (12, portrait 2400×3600)      SHAPEMATION SCORE: placed 12 · dropped 0 · centre median 0.000 p90 0.000 max 0.000 · scale median 0.000 · rotation median 0.0° · corners rms 0.0 px
mountains.clouds.mixed    (8, front / high / low)       SHAPEMATION SCORE: placed 8 · dropped 0 · centre median 0.000 p90 0.000 max 0.000 · scale median 0.000 · rotation median 0.0° · corners rms 0.0 px
city.clear.approach-c05   (σ_centre 0.05, seed 5)       SHAPEMATION SCORE: placed 12 · dropped 0 · centre median 0.065 p90 0.082 max 0.101 · scale median 0.000 · rotation median 0.0° · corners rms 13.7 px
```

The c05 twin reads as the dial says it should: a per-axis σ of 0.05 is a
radial residual with median 1.177 σ = 0.059 (twelve draws gave 0.065), the
scale and rotation residuals stay at 0 because the offset keeps both, and
the corner RMS is the same offset in canvas pixels (0.065 × 211 px ≈ 13.7).
The `high` view's face (aspect 0.792, width ÷ height as the Kit judges
it) is a `rectangle` by 0.008 — inside the old 0.05 refusal margin, now a
printed note — and stages and scores as one; nothing was dropped in any
of the 18 sets (60 scenes + the 12-scene twin, 72 in all).

Rendered from the same staged projects (`lapse shapemation render`, capture
order, 25 fps, 1 s each, `--size 1920`): `city.clear.approach` → 300 frames,
12.00 s, 1920×1280 (stack) and 600×400 (`--mode crop`, the 12th photo's own
footprint, the face at 211 px filling it); `oldtown.golden.approach` → 300
frames, 12.00 s, 1280×1920; the c05 twin → 300 frames, 12.00 s, 1920×1278.
Looked at: in the σ = 0 stack the tram face sits on one spot and every
footprint edge is invisible — lane lines and skyline run straight across the
nested layers; in the c05 stack the same layers show a jog at every edge
(each photo is placed by its perturbed register, 7–21 canvas px off the
anchor). The 12 `city.clear.approach` projects packed to `.lapse`, imported
one at a time through `LL_IMPORT_ARCHIVE` on a scratch root, and the app's
own builder (Rectangle → Any → Pick all → stack → 25 fps · 1 s → Fit 1920 →
Create) rendered them to a 1920×1280, 300-frame clip, largest first — the
brief's §8 loop closed on the kit's trams.

---

## First synthetic run, 2026-09-19 (placeholder tram — see the addendum above)

WP0 / WP1 / WP2 of `gap-map.md`, built to `synthetic-corpus.md` and run the
same day. Everything below was reproducible from `LetsLapse/` at 66e201c;
the placeholder generator those commands drove (`parts/`, `compose.py`,
`--scenes`) is gone, so the tables stand as history, not a recipe:

```
cd Kit && swift build -c release --product lapse && cd ..
tools/.venv/bin/python tools/shapesynth/shapesynth.py sweep --axis centre   --values 0,0.01,0.02,0.05,0.1,0.2 --scenes 30 --seed 3 --lapse Kit/.build/release/lapse
tools/.venv/bin/python tools/shapesynth/shapesynth.py sweep --axis scale    --values 0,0.01,0.02,0.05,0.1,0.2 --scenes 30 --seed 3 --lapse Kit/.build/release/lapse
tools/.venv/bin/python tools/shapesynth/shapesynth.py sweep --axis rotation --values 0,0.5,1,2,5,10          --scenes 30 --seed 3 --lapse Kit/.build/release/lapse
tools/.venv/bin/python tools/shapesynth/shapesynth.py sweep --axis joint    --values 0,0.01,0.02,0.05,0.1     --scenes 30 --seed 3 --lapse Kit/.build/release/lapse
```

Subject `tram_front` (a 1.0 × 0.65 body, aspect 1.54 head-on), viewpoint
`front`, 30 scenes per value on an approach run (true scale 0.2 → 1.0 of the
frame), 4032 × 3024, scored with `--family rectangle` — the builder's own
Match path. Seed 3 reuses one set of 30 standard-normal draws at every σ, so
each column scales linearly with σ and the ratios below are exact, not noise.

## 1. Acceptance

- **σ = 0 places every scene with zero residual** — centre, scale, rotation
  and corner RMS all at float noise (≤ 6 × 10⁻¹³ px on a 4032-wide frame),
  nothing dropped; on the clock (circle) set the same; on the posed sets
  (left / right / above / below at 22° yaw / 20° tilt) the same — a
  parallelogram truth maps exactly under the rectangle homography, so pose
  costs nothing at the alignment stage.
- **Orientation 6 == orientation 1** on 30 scenes to 1 × 10⁻⁹: a portrait-
  tagged JPEG stages and scores identically to the upright file.
- The Kit's 33 shape tests (ShapeBoundsTests 4 · ShapeDetectorTests 15 ·
  ShapemationMatchTests 8 · ShapemationPlanScoreTests 6) and the generator's
  123 self-checks pass.

## 2. The sweeps

`centre` = distance of the transformed truth centre from the anchor as a
fraction of the shape's placed size (`shapeSizePx`, 403 px here); `scale` =
|placed truth long side ÷ shapeSizePx − 1|; `rotation` = the placed truth's
top-edge angle; `corners rms` = against the target rectangle, in canvas
pixels; `overlap` = IoU of consecutive footprints in the sorted order.

### centre

| σ | placed | dropped | centre median | centre p90 | centre max | scale median | rotation median | corners rms px | overlap median |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 30 | 0 | 0 | 0 | 0 | 0 | 0° | 0 | 0.878 |
| 0.01 | 30 | 0 | 0.011 | 0.022 | 0.025 | 0 | 0° | 4.5 | 0.879 |
| 0.02 | 30 | 0 | 0.022 | 0.043 | 0.049 | 0 | 0° | 9 | 0.879 |
| 0.05 | 30 | 0 | 0.056 | 0.108 | 0.124 | 0 | 0° | 22.5 | 0.879 |
| 0.1 | 30 | 0 | 0.112 | 0.216 | 0.247 | 0 | 0° | 45.1 | 0.862 |
| 0.2 | 30 | 0 | 0.224 | 0.432 | 0.494 | 0 | 0° | 90.2 | 0.809 |

### scale

| σ | placed | dropped | centre median | centre p90 | centre max | scale median | rotation median | corners rms px | overlap median |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 30 | 0 | 0 | 0 | 0 | 0 | 0° | 0 | 0.878 |
| 0.01 | 30 | 0 | 0 | 0 | 0 | 0.005 | 0° | 1.2 | 0.872 |
| 0.02 | 30 | 0 | 0 | 0 | 0 | 0.010 | 0° | 2.5 | 0.870 |
| 0.05 | 30 | 0 | 0 | 0 | 0 | 0.026 | 0° | 6.3 | 0.864 |
| 0.1 | 30 | 0 | 0 | 0 | 0 | 0.052 | 0° | 12.7 | 0.856 |
| 0.2 | 30 | 0 | 0 | 0 | 0 | 0.104 | 0° | 25.2 | 0.832 |

### rotation

| σ | placed | dropped | centre median | centre p90 | centre max | scale median | rotation median | corners rms px | overlap median |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 30 | 0 | 0 | 0 | 0 | 0 | 0° | 0 | 0.878 |
| 0.5 | 30 | 0 | 0 | 0 | 0 | 0 | 0.4° | 1.5 | 0.872 |
| 1 | 30 | 0 | 0 | 0 | 0 | 0 | 0.7° | 3.1 | 0.867 |
| 2 | 30 | 0 | 0 | 0 | 0 | 0 | 1.5° | 6.2 | 0.859 |
| 5 | 30 | 0 | 0 | 0 | 0 | 0 | 3.7° | 15.4 | 0.838 |
| 10 | 30 | 0 | 0 | 0 | 0 | 0 | 7.3° | 30.7 | 0.769 |

### joint

| σ | placed | dropped | centre median | centre p90 | centre max | scale median | rotation median | corners rms px | overlap median |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 30 | 0 | 0 | 0 | 0 | 0 | 0° | 0 | 0.878 |
| 0.01 | 30 | 0 | 0.011 | 0.022 | 0.025 | 0.005 | 0.7° | 6.9 | 0.869 |
| 0.02 | 30 | 0 | 0.022 | 0.044 | 0.049 | 0.010 | 1.5° | 13.8 | 0.868 |
| 0.05 | 30 | 0 | 0.056 | 0.111 | 0.123 | 0.026 | 3.7° | 34.8 | 0.828 |
| 0.1 | 30 | 0 | 0.114 | 0.223 | 0.257 | 0.052 | 7.3° | 70.6 | 0.777 |

## 3. What the numbers say

**The scorer measures exactly what the dials do, and nothing leaks between
axes.** A centre offset of σ per axis lands as a centre residual with median
1.12 σ and p90 2.16 σ — the Rayleigh medians of a 2-D normal (1.18 σ,
2.15 σ) to within this seed's 30 draws — with scale and rotation at 0. A
scale dial lands only in `scale` (median 0.52 σ; 0.67 σ expected for |ln f|,
within the same 30-draw noise) and a rotation dial only in `rotation`
(0.73 σ; 0.67 σ expected). `joint` is the three superposed. Corner RMS is
the centre residual × shapeSizePx to the pixel.

**Why: the plan pins whatever shape was drawn to the anchor.** A shape drawn
3 % off the subject puts the *subject* 3 % off the anchor, exactly, on every
frame; a shape drawn 10 % too big puts the subject 10 % too small. Alignment
never breaks in the sense of losing a frame — `dropped` stayed 0 through
σ_centre 0.2 and σ_scale 0.2 — it degrades linearly, and what degrades is
the subject's *consistency from frame to frame*, which the residual against
truth is a proxy for.

**The 2 % break-point rule only sees the centre axis.** As written in the
contract (§6: first σ where the median `centre` residual exceeds 0.02), it
fires at σ_centre 0.02 (and at σ_joint 0.02, for the same reason) and reports
"none" for scale up to 0.2 and rotation up to 10° — because those dials do
not move the centre. That is not "scale and rotation never break"; it is a
rule keyed on one column. The size jitter at σ_scale 0.1 (every other frame
±5 % bigger) and the tilt at σ_rotation 5° (±3.7°) are plainly visible in
`corners rms` (12.7 px and 15.4 px on a 403 px shape) and in `overlap`
(0.856, 0.838 against 0.878 clean).

**So the deliverable the brief asks for — how accurately a person needs to
draw — needs eyes, not just this table.** The curves are linear and known;
the thresholds are perceptual. The next step is to render the σ sets as
clips (the renderer already takes the plan) and watch them: the σ at which
the tram visibly *shuffles* rather than *approaches* on each axis becomes the
per-axis gate (centre X %, scale Y %, rotation Z°), and the break-point rule
in `shapesynth.py` gains one threshold per column. Until that viewing, the
honest statement is: centre offset costs 1 : 1, scale 1 : 1, rotation 1 : 1,
and none of them loses a frame.

**Two things the corpus taught while being built.** The tram's first body
(1.0 × 0.8, aspect 1.25) sat exactly on `DetectedShape.family`'s square /
rectangle boundary, so float noise decided the family per scene (8 square /
4 rectangle in the first σ = 0 set) and `--family rectangle` would have
dropped two thirds of a clean corpus — the generator now refuses a truth
within 0.05 of a family boundary, and the register's family is `stage`'s
acceptance, not the kind. And without a family, quads take the plan's
similarity path (levelled by the top edge, no homography), which the builder
never uses: a posed σ = 0 set scores 5.7 px corner RMS there — `score` now
says so on stderr; every sweep passes the subject's family.

## 4. Not done here

- The perceptual thresholds above (a viewing session over rendered σ sets).
- Ellipse subjects under pose (the clock stays un-tilted; a foreshortened
  circle's exact ellipse truth is straightforward but not written).
- WP3 (sort by alignment) — `sequence.approach` is in every manifest ready
  to score an ordering against.
- WP4 — these staged folders are not library projects (no `project.json`,
  no `.lapse`); the app's builder cannot see them yet.

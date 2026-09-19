# shapesynth — synthetic scenes for the Shape-mation alignment scorer

Contract: `docs/shapemation/synthetic-corpus.md` (§2 manifest, §6 sweep and
break point, §8 layout). Answers the brief's §8 question: how far can the
register's shape drift from the truth before the plan's alignment breaks —
and which of the three dials breaks it first?

Everything runs in `tools/.venv` (Python 3.14, numpy, Pillow, opencv-headless
— no new packages; no cairosvg). `rsvg-convert` (Homebrew, `/opt/homebrew/bin`)
rasterises, Pillow writes the JPEG. Outputs land in `tools/shapesynth/work/`
(git-ignored). Nothing here reads or writes a library.

## Quick start (from `LetsLapse/`)

```
PY=tools/.venv/bin/python
$PY tools/shapesynth/shapesynth.py selftest                                    # generator only, no lapse needed (~15 s)
$PY tools/shapesynth/shapesynth.py generate --out tools/shapesynth/work/smoke --set zero --scenes 6 --seed 1
$PY tools/shapesynth/shapesynth.py generate --out tools/shapesynth/work --set clock --subject clock --viewpoints front,left,above \
        --sigma-scale 0.05 --sigma-centre 0.02 --sigma-rotation 2 --frame 4032x3024 --scene day-hills-road,night-city-road
$PY tools/shapesynth/shapesynth.py generate --out tools/shapesynth/work --set zero-o6 --scenes 6 --seed 1 --orientation 6   # portrait-tagged JPEGs, same manifests
cd Kit && swift build -c release --product lapse && cd ..                      # the CLI of contract §3–§5
$PY tools/shapesynth/shapesynth.py sweep --axis scale    --values 0,0.02,0.05,0.1,0.2 --scenes 60 --seed 1 --lapse Kit/.build/release/lapse
$PY tools/shapesynth/shapesynth.py sweep --axis centre   --values 0,0.01,0.02,0.05,0.1 --scenes 60 --seed 1
$PY tools/shapesynth/shapesynth.py sweep --axis rotation --values 0,0.5,1,2,5,10     --scenes 60 --seed 1   # degrees
$PY tools/shapesynth/shapesynth.py sweep --axis joint    --values 0,0.02,0.05,0.1    --scenes 60 --seed 1   # all three together
$PY tools/shapesynth/shapesynth.py sweep --axis scale --values 0,0.05 --reuse --score-flags "--sort capture"   # re-score kept sets
```

Every `score` (and so every sweep) runs with a family: the sweep adds
`--family <the subject's family>` (`rectangle` for `tram_front`, `circle`
for `clock`) unless `--score-flags` names one. Without a family `lapse
shapemation score` places quads by similarity — not the builder's
`rectanglePlacement` — and prints a note saying so; the zero-residual claims
below are for the family path, the one the app takes.

A 4032×3024 frame takes 2–4 s in rsvg-convert (cairo's 12 MP PNG encode is
most of it); frames of a set rasterise in parallel (`--jobs`, default half the
cores), so a 60-scene set is ~30 s and a five-value sweep a few minutes.

## What a scene is

`parts/` holds the SVG: skies (`day`, `dusk`, `night`, `overcast` — gradients),
grounds (`hills`, `city`, `field`, `road` — polygons, each with the y a subject
stands on) and subjects drawn frontal in local units with a KNOWN outline:

- `tram_front` — a stylised tram face; the outline is the body rectangle
  (1.0 × 0.65 local units — aspect 1.54, a `rectangle` to the Kit from every
  viewpoint; a 1.0 × 0.8 body sat exactly on the Kit's 1.25 square boundary),
  NOT the pantograph or the shadow. A quad truth.
- `clock` — a station clock on a post; the outline is the dial disc
  (radius 0.5). An ellipse truth.

A scene name is `<sky>-<ground>[-<ground>…]` (`day-hills-road`); the last
ground's stand line decides `cy`. `compose.py` places the subject with ONE
affine matrix — translate · scale · foreshorten, x by cos(yaw) and y by
cos(tilt) with a 0.12·sin shear to suggest the turned side — and `truth` is
the local outline through that same matrix: a quad truth is therefore a
parallelogram under any viewpoint but `front`, and a circle's truth is the
exact ellipse an affine makes of it (SVD of the linear part), so tilt and
yaw are honest for the clock too. Viewpoints: `front` (0, 0), `left`/`right`
(yaw ∓22°), `above`/`below` (tilt ±20°). The default viewpoint list is
`front`. A σ = 0 set scored **with the subject's family** scores zero under
every viewpoint (measured 2026-09-19: `cornerRmsPx` ~1e-13 on a
left/right/above/below set with `--family rectangle`; 5.7 px median on the
same set with no family, the similarity path) — the plan's rectangle
placement is a homography, and a parallelogram maps onto its target
rectangle exactly; the other viewpoints exercise the family gate (the seen
aspect shrinks by cos 22° under yaw), not the residual. Every scene carries
`subject.family` (`rectangle` for the tram, `circle` for the clock) and the
generator refuses a truth within 0.05 of the Kit's family boundary (seen
aspect against 1.25, obliquity against 0.85) — the yaw is 22° and not 30°
because at 30° the clock's obliquity was 0.854, one degree from `oval`.

`--orientation 6` stores every `frame.jpg` a quarter-turn anticlockwise
under EXIF orientation 6 — the way a phone's portrait JPEG is stored — with
the same manifest (its geometry is in the oriented frame). `lapse shapemation
stage` reads the header, applies the tag and refuses a file that does not
read at the manifest's frame size, so a register written on the stored size
cannot pass; the sweep stages its σ = 0 set both ways and requires the
per-item residuals to agree.

A set of N scenes is a run: `sequence.approach = index / (N − 1)` ∈ [0, 1],
the subject's scale grows geometrically with it (from a tenth of the width up
to what still fits above the stand line), `cx` drifts left → right with a
seeded wobble. Viewpoints and backgrounds are dealt round-robin over the run.

Coordinates everywhere: the frame's pixels, y down, origin top-left — SVG's
own space, the register's space (contract §1). Quad corners are clockwise
from top-left; an ellipse's `rotation` is the major axis's `atan2(dy, dx)`
(clockwise on screen in a y-down frame) wrapped to (−π/2, π/2] like the
Kit's. `scene.json` carries an optional `placement` block (contract §2:
cx, cy, scalePx, tilt, yaw, the 2×3 matrix; never read by the Kit) for
debugging a scene by eye.

## The dials (`perturb.py`)

`sigmaScale` — σ of a log-normal factor on the size (0.05 = ±5 %);
`sigmaCentre` — σ of a normal offset per axis **as a fraction of the truth's
major size** (scale-invariant); `sigmaRotationDeg` — σ of a normal in-plane
rotation in degrees. Applied in that order to a quad's corners (scale about
the centre, offset, rotation about the moved centre), so a perturbed quad is
a similar parallelogram and its `wide` flag survives; an ellipse perturbs its
centre, both semi-axes by the same factor, and its rotation. One
`default_rng([seed, 2])` stream per set (placement draws from `[seed, 1]`),
and every shape always takes its three draws scaled by the dials, so a dial
at 0 applies exactly nothing and one seed gives the same offsets whichever
dials are open. The `joint` axis moves all three together: the value on
scale and centre, value × `--joint-rotation-scale` (default 100 → 0.05 = 5°)
on rotation.

## What a sweep writes

```
work/<axis>-sweep/scenes/<set>/<id>/frame.jpg + scene.json + scene.svg   one set per value, <set> = "<axis>-<value>"
work/<axis>-sweep/projects/<set>/<id>/          `lapse shapemation stage` output (source/frame.jpg, shapes.json, scene.json)
work/<axis>-sweep/score-<set>.json              `lapse shapemation score … --json`
work/<axis>-sweep/lapse.log                     every lapse command, its output and exit code
work/<axis>-sweep/results.json                  per-value summaries (parsed from the SCORE line, the JSON filling gaps) + the break point
work/<axis>-sweep/report.md                     the table: placed · dropped · centre median/p90/max · scale · rotation · corners rms · overlap
```

The sweep stages once over the whole `scenes/` folder and scores per set,
handing `--score-flags` through as plan options (plus the subject's
`--family` unless one is named). `score` runs with `--json <file>`; under
`--json -` the Kit moves its readable lines, SCORE line included, to stderr
so a pipe gets the JSON alone — the sweep greps both streams for the SCORE
line. A missing binary, or one without the `shapemation` subcommand, is
reported with the build line; the sets are still generated and `--reuse`
re-scores them without redrawing.

The σ = 0 set is contract §5's acceptance, checked by the sweep and not by
eye: every scene placed, nothing dropped, every residual's max within 0.5 px
(`centre` and `scale` as 0.5 ÷ `shapeSizePx`, rotation as the angle 0.5 px
subtends over it, corners RMS in px) — else the sweep exits 1 with the
problems in `results.error` and the report. A row that placed nothing fails
the same way. The σ = 0 scenes are also generated as orientation-6 JPEGs
(`<set>-o6`), staged with the rest and scored; their per-item residuals
must equal the orientation-1 ones within 1e-9 (`ORIENTATION 6 FAILED …`
otherwise).

## The BREAK POINT rule (contract §6)

Per axis, the break point is **the first value at which the median `centre`
residual exceeds 0.02** (2 % of `shapeSizePx`), printed and written as one
greppable line:

```
BREAK POINT scale: σ 0.1 (median centre 0.024; 0.05 gave 0.011)
BREAK POINT centre: none up to σ 0.2
BREAK POINT centre: not scored                  ← no set produced a median (the sweep already failed)
```

σ is printed as given (`0.025` stays `0.025`). `dropped` (the Kit's own
closed set of reasons: `majorPx <= 0`, `no admissible shape`, `register
unreadable`, `plan returned nil`, `plan skipped it`, `scene.json unreadable`)
sits beside the residuals in the table and is never folded into them — a set
that lost members is not a clean set. On an exact plan the `centre` axis's
break point is the dial's own definition (the offset is per axis, so the
radial residual has median 1.177 σ and crosses 0.02 at σ ≈ 0.017), not a
property of the pipeline; the axis says something once a real detector
replaces the perturbed register.

## Selftest

Generator-only, no lapse: σ = 0 gives perturbed == truth to 1e-9 for both
subjects at every viewpoint, and every truth lands in the subject's intended
family with ≥ 0.05 of margin from the Kit's boundary; a quad perturbed at
σ > 0 is still a parallelogram, clockwise from top-left (positive shoelace
area in y-down, corner 0 at the smallest x + y); σ_scale 0.1 over 200 draws
has a log std within 20 % of 0.1 (σ_centre and σ_rotation likewise); the same
seed reproduces a set; a rasterised frame has the requested size and EXIF
orientation 1; an `--orientation 6` frame stores H×W under tag 6, reads as
W×H, carries the same manifest and — once the tag is honoured — is the
orientation-1 picture to JPEG noise; `scene.json` validates every key of
§2 (`subject.family` included); and the raster agrees with the truth —
probes just inside the outline's corners land on the body colour, probes
just outside do not. The SCORE-line parser (with the Kit's `n/a` fields),
the break-point rule, the σ = 0 acceptance and the o6 == o1 comparison are
checked on the contract's own examples.

# Shape-mation — the synthetic corpus and the alignment scorer

The contract for the brief's §8 and §9 step 1 (`brief.md`), decided 2026-09-19
with Steven: a Swift `lapse shapemation` subcommand in the Kit does the
register writing, the plan and the score (one code path — the same
`DetectedShape` factories and the same `ShapemationPlan.make` the app uses);
Python in `tools/.venv` draws the scenes, rasterises them, runs the sweeps and
writes the report. Work packages WP0 / WP1 / WP2 of `gap-map.md`.

## 1. Coordinates, once

Everything the two sides exchange is in the **oriented frame's pixels,
y-down, origin top-left** — the space `DetectedShape.ellipse(centre:…frame:)`
and `DetectedShape.quad(corners:frame:)` take (`ShapeRegister.swift`). The
Kit normalises on the way into `shapes.json` (centre per axis, axes as a
fraction of the frame's WIDTH, corners per axis); Python never writes
normalised numbers and never writes `shapes.json`.

Angles are radians from +x, in the sense `atan2(dy, dx)` gives in the y-down
frame — clockwise on screen — for a quad's top edge; Python uses the same
convention and the Kit's `quadMetrics` re-derives it from the corners anyway. Pose
(tilt, yaw) is in degrees in the manifest and is **not** a register field
yet (§2 of the brief, WP10); the corpus carries it as truth so the scorer can
report residual against pose later.

## 2. The scene manifest — `scene.json` (Python → Swift)

One folder per scene, `<scenes>/<set>/<scene-id>/`, holding `frame.jpg`
(EXIF orientation 1, quality 92, the frame size below — or, from
`generate --orientation 6`, the same picture stored a quarter-turn
anticlockwise under orientation 6 so it reads at the frame size once the tag
is honoured, the way a phone's portrait JPEG does; the manifest is identical
either way) and:

```json
{
  "schema": 1,
  "id": "front-0042",
  "set": "scale-0.05",
  "frame": { "width": 4032, "height": 3024 },
  "subject": { "part": "tram_front", "viewpoint": "front", "scene": "day-hills-road", "family": "rectangle" },
  "sequence": { "index": 42, "of": 100, "approach": 0.42 },
  "truth":     { "kind": "quad", "cornersPx": [[x,y],[x,y],[x,y],[x,y]], "tiltDeg": 0, "yawDeg": 0 },
  "perturbed": { "kind": "quad", "cornersPx": [[x,y],[x,y],[x,y],[x,y]] },
  "perturbation": { "sigmaScale": 0.05, "sigmaCentre": 0, "sigmaRotationDeg": 0, "seed": 4242 }
}
```

- `kind` is `quad` or `ellipse`. An ellipse carries `centrePx: [x, y]`,
  `semiAxesPx: [a, b]` (a ≥ b), `rotation` (radians) instead of `cornersPx`.
  Quad corners are **clockwise from top-left** (the register's order).
- `truth` is exact — the subject part's outline quad through the placement
  transform. `perturbed` is what the pipeline is given: the truth with the
  three dials applied, quads perturbed **through their corners** (scale about
  the centre, then the centre offset, then the rotation about the centre) so
  a perturbed quad is still a parallelogram of the truth and its `wide` flag
  survives.
- The dials: `sigmaScale` is the σ of a log-normal factor on the size
  (0.05 = ±5 %); `sigmaCentre` is the σ of a normal offset **per axis** (two
  independent draws, x and y) **as a fraction of the truth's major size**
  (scale-invariant: a 5 % offset on a small subject is small);
  `sigmaRotationDeg` is the σ of a normal in-plane rotation in degrees. A
  dial at 0 applies nothing. `seed` makes a set reproducible.
- `sequence.approach` ∈ [0, 1] is where the scene sits in its run — the
  subject's true scale grows monotonically with it — so a size sort or an
  alignment chain can be scored against the true order (WP3).
- `subject.scene` names the background recipe; `subject.viewpoint` is one of
  `left`, `right`, `front`, `above`, `below`. `subject.family` is the Kit
  family (`circle` | `oval` | `square` | `rectangle`) the outline intends
  under that viewpoint — what the staged register must load back as. The
  generator refuses a scene whose truth sits within 0.05 of a family boundary
  (seen aspect against 1.25, obliquity against 0.85: `DetectedShape.family`),
  so a set never stages green and then drops under `--family`.
- `placement` (optional, debugging only, never read by the Kit): how the
  truth was made — `cx`, `cy`, `scalePx`, `tiltDeg`, `yawDeg` and the 2×3
  placement matrix — so a scene can be checked by eye.

## 3. The staged project (Swift writes it)

`lapse shapemation stage <scenes-dir> --out <projects-dir>` turns every scene
folder it finds (recursively, by `scene.json`) into a project folder:

```
<projects-dir>/<set>/<scene-id>/
  source/frame.jpg      copied (or hard-linked with --link)
  shapes.json           ShapeRegister.manual(representative:) + one DetectedShape
                        from `perturbed` via the Kit factories, source .manual;
                        representative.relativePath "source/frame.jpg",
                        width/height from the manifest; horizontalFieldOfView nil
  scene.json            the manifest, copied — the truth travels with the project
```

No `project.json` in this step: the CLI's `plan`/`score` read the register and
the manifest only. Making it a real library project (`project.json`, the
`.lapse` archive, the import door) is WP4 — see `gap-map.md`. `stage`'s
acceptance, exit 1 on either: `frame.jpg` must read at the manifest's frame
size with its EXIF orientation applied (header only, no pixel decoded — an
orientation-6 file stores the axes swapped), and the register must load back
through `ShapeRegister.load(inProjectFolder:)` with the family the scene
intended (`DetectedShape.family` == `subject.family`; every mismatch is
printed as `<set>/<id>: loaded back as … , the scene intended …`). Each
staged scene prints `<set>/<scene-id> <family>`.

## 4. The plan — `lapse shapemation plan`

`lapse shapemation plan <project…> [--mode stack|crop] [--family circle|oval|square|rectangle] [--sort largest|smallest|capture] [--json <file>]`

One `ShapemationItem` per project folder: `id` = the RFC 4122 version-5
UUID of `<set>/<scene-id>` in the URL namespace (stable across runs;
`uuid.uuid5(uuid.NAMESPACE_URL, "<set>/<scene-id>")` reproduces it),
`pixelSize` from the register's representative (no image decode), `shape` =
the register's first shape admissible to the family (all shapes when no
family is given, largest `nativeDiameterPx` wins). `--family` builds the
`ShapeMatch(family:)` the app's Match step would pass (default strictness);
that one match decides admissibility (`ShapeMatch.matches`) and is handed to
the plan, so quads go through `rectanglePlacement` exactly as in the builder.
`--sort` is `ShapemationSort`; default `largest`. Then
`ShapemationPlan.make(items:mode:match:)`.

JSON out (`--json`, else a table on stdout):

```json
{
  "mode": "stack", "family": "rectangle", "sort": "largestFirst",
  "shapeSizePx": 812.0, "anchor": [x, y], "canvas": [w, h], "unionCanvas": [w, h],
  "items": [
    { "id": "…", "project": "scale-0.05/front-0042", "scale": 0.61,
      "transform": [9 numbers, row-major, source px → canvas px],
      "footprint": [x, y, w, h],
      "placed": { "kind": "quad", "cornersPx": [[…]] }      // the REGISTER shape through the transform
    }
  ],
  "dropped": [ { "project": "…", "reason": "majorPx <= 0" | "no admissible shape" | "register unreadable" | "plan returned nil" | "plan skipped it" | "scene.json unreadable" } ]
}
```

`dropped` is not optional: `ShapemationPlan.make` silently `continue`s on a
degenerate shape and returns nil on an empty crop intersection; a scorer that
counts only what was placed reports a clean run on a corpus that lost members.
The reasons are a closed set so a report can group by them: `plan skipped it`
is the guard for a skip in `make` the pre-checks did not name (unreachable
today, kept so a new skip can never lose a project quietly); `scene.json
unreadable` is `score`'s, for a placed item whose truth cannot be read (the
error itself goes to stderr).

## 5. The score — `lapse shapemation score`

`lapse shapemation score <project…> [plan options] [--json <file>]`

Runs the plan, then for every placed item reads `scene.json` and pushes the
**truth** shape (pixels) through the item's transform. The plan promises that
the register shape lands centred on `anchor` at `shapeSizePx` (long side)
and levelled (quads by their top edge, circles round, ovals level). So:

- `centrePx` — distance in canvas pixels from the transformed truth centre to
  `anchor`; **`centre` = `centrePx / shapeSizePx`** (the headline residual).
- `scale` — transformed truth long side ÷ `shapeSizePx` − 1.
- `rotationDeg` — the transformed truth's top-edge angle (quads) or major-axis
  angle (ovals; 0 for circles by definition) in degrees.
- Quads also get `cornerRmsPx` against the rectangle the plan targets
  (centred on `anchor`, long side `shapeSizePx`, aspect = the truth's own
  effective aspect, orientation by `wide`) — the honest projective residual.

`rotationDeg` is a residual only under a family that levels the shape —
quads through `rectanglePlacement` under `--family square|rectangle`, ovals
under `--family oval`; with no family an ellipse is placed unturned and the
number is its placed angle. Give `--family` (the sweep always does).

Aggregates per invocation: count placed / dropped (by reason), `centre`
median · p90 · max, `scale` median · p90, `rotationDeg` median · p90,
`cornerRmsPx` median · p90; `pairwiseOverlap` median (IoU of consecutive
placed footprints in the sorted order — the "does it read as one motion"
number). Stdout ends with one greppable line:

```
SHAPEMATION SCORE: placed 98 · dropped 2 · centre median 0.004 p90 0.019 max 0.071 · scale median 0.006 · rotation median 0.3° · corners rms 2.1 px
```

Under `--json -` the readable lines, SCORE line included, go to stderr so a
pipe gets the JSON alone; the sweep greps both streams.

On an **unperturbed** set scored with `--family <the subject's family>`,
every residual is 0 within 0.5 px and `dropped` is 0 — the multi-item Kit
test asserts exactly that on three hand-built items
(`ShapemationPlanScoreTests`), and `score` on `stage`'s output of a σ = 0
set is the CLI's acceptance. The family matters: without one quads are
placed by similarity (levelled and scaled), not the builder's
`rectanglePlacement`, and a posed σ = 0 set then scores a corner residual
the app never sees (measured 2026-09-19: 5.7 px median on a left/right/
above/below tram set, 0 with `--family rectangle`).

## 6. The sweep and the break point (Python)

`tools/shapesynth/shapesynth.py sweep --axis scale|centre|rotation|joint --values 0,0.02,0.05,0.1,0.2 --scenes 60 --seed 1 --lapse Kit/.build/release/lapse`

generates one set per value (the other two dials at 0; `joint` moves all
three together), stages, scores — with `--family <the subject's family>`
unless `--score-flags` names one — and collects `results.json` +
`report.md` under `tools/shapesynth/work/<sweep-name>/`. The σ = 0 set is
§5's acceptance and the sweep fails (exit 1, `results.error`) unless every
scene was placed, nothing dropped and every residual is within 0.5 px
(`centre` and `scale` as 0.5 ÷ `shapeSizePx`); a row that placed nothing
fails too. The σ = 0 scenes are also staged a second time as orientation-6
JPEGs (`<set>-o6`) and their per-item residuals must equal the
orientation-1 ones within 1e-9 — the oriented-frame acceptance of WP1/WP2.
The break point per axis is **the first value at which the median `centre`
residual exceeds 0.02 (2 % of `shapeSizePx`)**, reported as a greppable line
per axis (σ printed as given, `0.1` not `0.10`):

```
BREAK POINT scale: σ 0.1 (median centre 0.024; 0.05 gave 0.011)
BREAK POINT centre: none up to σ 0.2
BREAK POINT centre: not scored            ← the failure form: no set produced a median
```

"Which axis breaks first" is the brief's deliverable; the report tabulates
every value with placed/dropped/median/p90 so the curve, not just the
threshold, is there. `dropped` is reported beside `misaligned`, never folded
in. On an exact plan (the register is the perturbed truth itself, no
detector between them) the `centre` axis's break point is the dial's own
definition, not a measurement: the offset is per axis, so the radial residual
is Rayleigh with median 1.177 σ and crosses 0.02 at σ ≈ 0.017; the axis
becomes informative once a real detector replaces the perturbed register.

## 7. WP0 — the Kit helpers this rests on

- `DetectedShape.bounds(in frame: CGSize) -> CGRect` — the axis-aligned
  bounds in the frame's pixels (an ellipse from its rotated axes, a quad from
  its corners), and `margins(in frame:) -> (left, top, right, bottom)` in
  pixels, signed (negative = the shape spills out). Beside
  `remeasured(frame:)`; **not** `ShapeDetector.bbox`, which mixes
  width-fraction axes into a y offset and stays as it is under its fifteen
  tuned thresholds (`gap-map.md`, WP0c). The unused public
  `ShapeDetector.bounds(of:)` goes.
- `ShapemationSort.newestFirst` → `captureOrder`, title "Capture order"
  (what it always did: the order given, oldest → newest as the builder loads
  them); the builder's own sort switch collapses onto the Kit's rule through
  `ShapemationSort.sorted(_:share:)`, a generic overload keyed by a share
  closure, so the builder and the CLI order the same way.
- Tests: `bounds(in:)`/`margins(in:)` for a circle on 4:3 and 16:9 frames, a
  rotated ellipse, a quad; the rename in `ShapemationMatchTests`.

## 8. Where things live

```
Kit/Sources/lapse/ShapemationCommand.swift     stage · plan · score (hand-rolled argv like framing)
Kit/Tests/LetsLapseKitTests/ShapemationPlanScoreTests.swift
tools/shapesynth/                               Python: parts/ (SVG fragments), compose.py, rasterise.py,
                                                perturb.py, shapesynth.py (generate · sweep · selftest), README.md
tools/shapesynth/work/                          git-ignored outputs
```

Build the CLI with `cd Kit && swift build -c release --product lapse`;
Python runs from `LetsLapse/` as `tools/.venv/bin/python
tools/shapesynth/shapesynth.py …` (the shapebench precedent). `rsvg-convert`
(`/opt/homebrew/bin`) rasterises; Pillow writes the JPEG.

# shapesynth — the scene kit as a corpus for the Shape-mation alignment scorer

Contract: `docs/shapemation/synthetic-corpus.md` (§2 manifest, §6 sweep and
break point, §8 layout). Answers the brief's §8 question: how far can the
register's shape drift from the truth before the plan's alignment breaks —
and which of the three dials breaks it first?

**The kit is the generator.** `docs/design/kit/` (its README has the recipe
fields) holds the Prague T3 tram at five views, six skies and five scenes
(100 compositions: 48 in four approach sequences, 12 singles, 40
`mixed.random.*`); `build.js` composes `recipes.json` into
`compositions/<id>.svg` + `compositions/manifest.json` through a
one-point-perspective road camera in metres, and every composition root
carries the tram FACE polygon
(`<polygon data-role="shape">`), its bounds (`data-shape-bbox`), per-side
margins, the 3×3 cell overlaps and the cell — the brief's §5/§6 inputs,
pre-computed. Nothing is drawn here. To add a scene, add a recipe line and
rebuild:

```
node docs/design/kit/build.js        # objects/, skies/, scenes/, compositions/*.svg + manifest.json
```

shapesynth **rasterises** the compositions, writes the scene manifests,
**perturbs** the truth with the three dials, **stages** and **sweeps**.
Everything runs in `tools/.venv` (Python 3.14, numpy, Pillow, opencv-headless
— no new packages; no cairosvg). `rsvg-convert` (Homebrew, `/opt/homebrew/bin`)
rasterises, Pillow writes the JPEG. Outputs land in `tools/shapesynth/work/`
(git-ignored). Nothing here reads or writes a library, and nothing writes
under the kit.

## Quick start (from `LetsLapse/`)

```
PY=tools/.venv/bin/python
$PY tools/shapesynth/shapesynth.py selftest                                            # kit reader + generator, no lapse (~2 s)
$PY tools/shapesynth/shapesynth.py generate --out tools/shapesynth/work/kit --sequence all      # every composition, 100 scenes
$PY tools/shapesynth/shapesynth.py generate --out tools/shapesynth/work/kit --sequence city.clear.approach \
        --sigma-scale 0.05 --sigma-centre 0.02 --sigma-rotation 2 --seed 1 --set-suffix=-wobble
$PY tools/shapesynth/shapesynth.py generate --out tools/shapesynth/work/kit --sequence single --orientation 6 --set-suffix=-o6
$PY tools/shapesynth/shapesynth.py generate --out tools/shapesynth/work/mixed --sequence all --pool mixed-all           # 100 photos, ONE set, ranked by face share
$PY tools/shapesynth/shapesynth.py select tools/shapesynth/work/mixed --where tram=front --where cell=centre           # folders, one per line
$PY tools/shapesynth/shapesynth.py recipes --mixed 40 --seed 19 --kit <copy of docs/design/kit> --dry-run             # the mixed.random batch
cd Kit && swift build -c release --product lapse && cd ..                              # the CLI of contract §3–§5
$PY tools/shapesynth/shapesynth.py sweep --axis scale    --values 0,0.02,0.05,0.1,0.2 --seed 1 --lapse Kit/.build/release/lapse
$PY tools/shapesynth/shapesynth.py sweep --axis centre   --values 0,0.01,0.02,0.05,0.1 --seed 1
$PY tools/shapesynth/shapesynth.py sweep --axis rotation --values 0,0.5,1,2,5,10     --seed 1   # degrees
$PY tools/shapesynth/shapesynth.py sweep --axis joint    --values 0,0.02,0.05,0.1    --seed 1   # all three together
$PY tools/shapesynth/shapesynth.py sweep --axis scale --values 0,0.05 --sequence oldtown.golden.approach   # portrait, 2400×3600
$PY tools/shapesynth/shapesynth.py sweep --axis scale --values 0,0.05 --reuse --score-flags "--sort capture"   # re-score kept sets
```

A value that starts with `-` goes through `=` (`--set-suffix=-c05`), or
argparse reads it as an option.

The doors out of the corpus into the app (contract §3.1; `lapse` built as
above):

```
L=Kit/.build/release/lapse
$L shapemation stage tools/shapesynth/work/kit --out tools/shapesynth/work/kit-projects --project    # + project.json / assets.ndjson: a Photo project per scene
$L shapemation score  tools/shapesynth/work/kit-projects/city.clear.approach/* --family rectangle
$L shapemation render tools/shapesynth/work/kit-projects/city.clear.approach/* --out city.mp4 --family rectangle --sort capture --fps 25 --hold 1s --size 1920
$L shapemation pack   tools/shapesynth/work/kit-projects/city.clear.approach/* --out <dir>          # one <id>.lapse per project
LL_IMPORT_ARCHIVE=<dir>/<id>.lapse <Debug LetsLapse.app>/Contents/MacOS/LetsLapse -ApplePersistenceIgnoreState YES -storage.libraryRootPath <scratch root>
```

`LL_IMPORT_ARCHIVE` takes one archive per launch; a staged sequence is
twelve launches, then `LL_SHAPEMATION=build` opens the builder over them
(Rectangle · 12 projects, "1 rectangle · Photo · Imported" per row; the
pre-filled path is dropped on the Mac too, so press "Create shape slideshow"
by AX). Measured 2026-09-19: the app rendered the twelve `city.clear.approach`
projects to a 1920×1280, 300-frame clip, largest first — the same plan
`render --sort capture` makes in approach order.

`--kit` defaults to `docs/design/kit`; `--sequence` is a kit sequence
(`city.clear.approach`, the sweep's default), a dotted prefix (`single` is
every single) or `all`. `--scale` (default 2) is raster px per kit px, so a
1800×1200 composition becomes a 3600×2400 frame and the portrait 1200×1800
ones 2400×3600. A frame takes ~0.3 s in rsvg-convert and frames rasterise in
parallel (`--jobs`, default half the cores): all 100 in ~6 s.

Every `score` (and so every sweep) runs with a family: the sweep adds
`--family <the sequence's family>` — `rectangle` for every tram sequence —
unless `--score-flags` names one. Without a family `lapse shapemation score`
places quads by similarity, not the builder's `rectanglePlacement`, and
prints a note saying so; the zero-residual claims below are for the family
path, the one the app takes.

## What a scene is

One kit composition. `kit.py` reads `compositions/manifest.json` and each
SVG's root-level `<polygon data-role="shape">` (the LAST one in the file —
the first sits inside the inlined object at object-local coordinates) and
writes, per contract §2:

- `set` — the sequence: the id minus its trailing `.<nn>` (`city.clear.approach`
  for `city.clear.approach.07`), plus `--set-suffix`. A composition without a
  number (`single.hills.sun.high`) is a sequence of one.
- `sequence` — `index`/`of` from the numbering, `approach = index / (of − 1)`
  (0 for a single). The recipes' `size` (tram height as a fraction of frame
  height) is strictly monotonic within every numbered sequence on one frame
  size, and the face share within a mixed-frame one (`mixed.random`) — the
  selftest checks it — so the true scale grows with `approach` as §2 wants.
  Under `--pool` the set is the pool and the index its rank by share.
- `subject` — `part` `tram-face`, `viewpoint` the manifest's tram view
  (`front` | `left` | `right` | `high` | `low`), `scene`, `sky`, and `family`
  by the Kit's own rule on the face's bbox (below).
- `truth` — the register knows `ellipse | quad` only, so the truth is a
  **quad: the face's axis-aligned bbox** (`data-shape-bbox` × scale),
  clockwise from top-left, tilt 0, yaw 0. Exact from the manifest.
- `perturbed` — `perturb.py` on those corners.
- `truthPolygon` — the seven-point face polygon × scale, for the brief's §2
  outline inventory when the register grows a polygon kind.
- `kit` — `id`, `margins`, `cells`, `cell`, `distance`, `size`, `cx`,
  `camera`, `camH`, `track`, `vp`, the kit size, `scale` and the file, copied
  from the manifest so §5/§6 work can be checked against the kit's numbers.

The Kit's `SceneManifest` (`ShapemationScore.swift`) is synthesised
`Codable` with no `CodingKeys`, so `JSONDecoder` ignores `truthPolygon` and
`kit` the way it ignored `placement` before. `scene.svg` beside each
`frame.jpg` is the composition itself.

### The family note (`high`)

`DetectedShape.family` calls a quad `square` while its width ÷ height is
within 0.8…1.25 and `rectangle` past it (a tall face is judged against
0.8, a wide one against 1.25; the margins here are in those units). The
front face is 460 × 660 kit units, aspect 0.697 — a rectangle by 0.103 —
and `left`/`right`/`low` reuse it. The `high` view is the same face
squashed by 0.88: 460 × 580.8, aspect **0.792, a rectangle by 0.008**.
That is inside the old 0.05 boundary margin,
so the margin rule is now two-tier: under 0.05 the generator prints a note
(`mountains.clouds.mixed.01`, `.05`, `single.hills.sun.high`,
`single.hills.night.high` today), and only under 0.002 — where float noise
after the Kit's normalisation could flip it — is a scene refused. The dials
cannot eat it: scale is isotropic, the offset and the rotation keep the
aspect. Every one of the 100 compositions is a `rectangle` (the eight `mixed.random` `high` views join the near list).

`--orientation 6` stores every `frame.jpg` a quarter-turn anticlockwise
under EXIF orientation 6 — the way a phone's portrait JPEG is stored — with
the same manifest (its geometry is in the oriented frame); a reader that
honours the tag sees the frame upright again.

## The mixed pool (`--pool`, `select`, `recipes`)

Steven, 2026-09-19: a single-scene approach clip is not a true test — real
captures put the same object into DIFFERENT scenes, and the object (and so
its recorded shape) is the one constant. Three doors:

- `recipes --mixed 40 --seed 19` (`recipes_mixed.py`) appends a seeded
  `mixed.random.01…40` batch to the kit's `recipes.json`: aspect over all
  five, scene × sky uniform, track left/right (the depot also ±5.25), camera
  left/centre/right, `size` log-uniform 0.08…0.75, `cx` uniform 0.15…0.85,
  the five tram angles cycling so each appears eight times — explicitly, so
  the drawn flank overrides the camera/track geometry (`build.js`'s
  `angleFor`) and contradicts it in 17 of the 24 ground views of the seed-19
  batch; `tram`/`viewpoint` is the drawn label, not where the photographer
  stood (kept as drawn, ids are referenced; a next batch should cycle only
  `high`/`low` and let the geometry label the rest). Every candidate
  is composed through the kit's own `build.js` and refused when the face is
  not inside the frame by 2 % per side (a `high` camera drops a near face
  below the frame; a portrait frame cannot hold a 0.75 face at cx 0.15);
  refused slots redraw from the same stream, so a seed is a batch. The batch
  is numbered by face SHARE (the Kit's sort key: face major ÷ frame short
  edge), not `size`, which is a fraction of the frame height and ranks a
  portrait face under a landscape one. Idempotent: a kit that already holds
  `mixed.random.*` is left alone (exit 1). Rebuild in a COPY of the kit
  (`build.js` re-serialises every composition, and the checked-in 60 carry a
  block a tool injected) and copy back only the new SVGs + `manifest.json`.
- `generate … --sequence all --pool mixed-all` lands every selected
  composition in ONE set, `sequence.index` = rank by share ascending (0 =
  smallest face), `of` = count, `approach` = rank ÷ (count − 1); the ids
  stay the compositions'. Staged with `--project`, the projects' capture
  dates follow the rank, so the app's Capture order is smallest first.
- `select <scenes-or-projects-dir> --where tram=front --where cell=centre,mixed`
  prints the matching folders one per line in set + rank order (keys: tram,
  scene, sky, cell, aspect, family, set, id; comma = any of), so a variant of
  the pool is a shell substitution:
  `lapse shapemation score $(shapesynth.py select <projects>/mixed-all --where tram=front) --family rectangle`.

Measured 2026-09-19 on the 100-composition kit at `--scale 2`,
`--family rectangle`: `mixed-all` (σ = 0) places 100, drops 0, every residual
0; `mixed-perturbed` (`--sigma-centre 0.05 --sigma-rotation 2 --seed 7`)
centre median 0.060 p90 0.108, rotation median 1.3°, corners rms 9.0 px.
The plan's working scale is the smallest face — 140.8 px
(`single.mountains.dusk.tiny`) — and `--mode crop` over the whole pool
collapses to a 128 × 226 px canvas against a 4077 × 2400 union: the
intersection of a hundred mixed framings is smaller than the face itself.

## The dials (`perturb.py`)

`sigmaScale` — σ of a log-normal factor on the size (0.05 = ±5 %);
`sigmaCentre` — σ of a normal offset per axis **as a fraction of the truth's
major size** (scale-invariant); `sigmaRotationDeg` — σ of a normal in-plane
rotation in degrees. Applied in that order to a quad's corners (scale about
the centre, offset, rotation about the moved centre), so a perturbed quad is
a similar parallelogram and its `wide` flag survives. One
`default_rng([seed, 2])` stream per set, drawn in sequence order, and every
shape always takes its three draws scaled by the dials, so a dial at 0
applies exactly nothing and one seed gives the same offsets whichever dials
are open. The `joint` axis moves all three together: the value on scale and
centre, value × `--joint-rotation-scale` (default 100 → 0.05 = 5°) on
rotation.

## What a sweep writes

```
work/<axis>-sweep/scenes/<sequence>-<axis>-<value>/<id>/frame.jpg + scene.json + scene.svg   one set per value
work/<axis>-sweep/projects/<sequence>-<axis>-<value>/<id>/   `lapse shapemation stage` output (source/frame.jpg, shapes.json, scene.json)
work/<axis>-sweep/score-<axis>-<value>.json                  `lapse shapemation score … --json`
work/<axis>-sweep/lapse.log                                  every lapse command, its output and exit code
work/<axis>-sweep/results.json                               per-value summaries (parsed from the SCORE line, the JSON filling gaps) + the break point
work/<axis>-sweep/report.md                                  the table: placed · dropped · centre median/p90/max · scale · rotation · corners rms · overlap
```

The sweep stages once over the whole `scenes/` folder and scores per value
(every sequence selected, one `score` call), handing `--score-flags` through
as plan options (plus the family unless one is named). `score` runs with
`--json <file>`; under `--json -` the Kit moves its readable lines, SCORE
line included, to stderr so a pipe gets the JSON alone — the sweep greps
both streams. A missing binary, or one without the `shapemation`
subcommand, is reported with the build line; the sets are still generated
and `--reuse` re-scores them without redrawing.

The σ = 0 set is contract §5's acceptance, checked by the sweep and not by
eye: every scene placed, nothing dropped, every residual's max within 0.5 px
(`centre` and `scale` as 0.5 ÷ `shapeSizePx`, rotation as the angle 0.5 px
subtends over it, corners RMS in px) — else the sweep exits 1 with the
problems in `results.error` and the report. A row that placed nothing fails
the same way. The σ = 0 scenes are also generated as orientation-6 JPEGs
(`<sequence>-<axis>-0-o6`), staged with the rest and scored; their per-item
residuals must equal the orientation-1 ones within 1e-9 (`ORIENTATION 6
FAILED …` otherwise). Measured 2026-09-19 on `city.clear.approach` at
`--family rectangle`: σ = 0 places 12, drops 0, every residual 0; σ_scale
0.05 gives scale median 0.049, corners rms 5.9 px, centre 0.

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

Kit reader + generator, no lapse: every composition's root polygon has seven
points and its bbox equals `data-shape-bbox` to 0.1 px (the kit rounds both
to one decimal separately) and the manifest's bbox exactly; every
composition's family is `rectangle` with its margin, the near ones listed
and all of them `high`; numbered sequences run 1…n with `size` and
`approach` strictly increasing, singles have approach 0; σ = 0 gives
perturbed == truth to 1e-9 for all 100 with the truth equal to bbox × scale,
corners clockwise from top-left, `truthPolygon` and the `kit` block copied,
and `scene.json` validating every key of §2; the same seed reproduces a set,
a different one does not; a quad perturbed at σ > 0 is still a
parallelogram, clockwise from top-left; σ_scale 0.1 over 200 draws has a log
std within 20 % of 0.1 (σ_centre and σ_rotation likewise); a landscape
(1800×1200 → 3600×2400) and a portrait (1200×1800 → 2400×3600) composition
rasterise at the requested size with EXIF orientation 1, and on the
clear-sky one a probe on the face's red band is the tram red while probes
just outside the bbox are not; an `--orientation 6` frame stores H×W under
tag 6, reads as W×H, carries the same manifest and — once the tag is
honoured — is the orientation-1 picture to JPEG noise. The SCORE-line parser
(with the Kit's `n/a` fields), the break-point rule, the σ = 0 acceptance
and the o6 == o1 comparison are checked on the contract's own examples.

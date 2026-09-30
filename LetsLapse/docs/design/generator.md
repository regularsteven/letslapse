# Synthetic image generator (`letslapse-generator`)

The scene kit that used to live here (`docs/design/kit`) moved on 2026-09-30
into its own repository, with its history:

- **Where:** `letslapse-generator`, checked out beside this repository
  (`~/Documents/dev/letslapse-generator`). The kit itself is its `kit/`
  folder: `recipes.json`, the tram, sky and scene parts, the 100 reference
  compositions and their `manifest.json`, and `build.js`, now frozen.
- **What it is:** a generator of synthetic photographs with exact ground
  truth. Every scene is composed from parameters, rendered SVG → JPEG, and
  written with a JSON record of exactly what is in it. It exists to measure
  LetsLapse's image analysis (shapes, attached features, viewing angle,
  colour, visibility) against answers known by construction. It has its own
  lifecycle and is not gated on app builds.
- **The contract:** the output folder, `<out>/<set>/<id>/frame.jpg` +
  `scene.json` (+ `scene.svg`). The record is versioned by `schema_version`
  and documented in the generator's `SCHEMA.md`. It keeps the Kit's staging
  keys (`schema: 1`, `id`, `set`, `frame`, `subject`, `sequence`, `truth`,
  `perturbed`, `perturbation` — `SceneManifest` in
  `Kit/Sources/LetsLapseKit/Shapes/ShapemationScore.swift`) and adds its own
  beside them. The Kit ignores the extra keys.

## What it generates

The record is `schema_version` 2.0 (SCHEMA.md in the generator repository).
Every object in a scene gets:

- **type and role**, and its **core primitive**: rectangle, circle or
  ellipse, or the upper half for arches. The primitive carries its
  continuous aspect ratio, centroid, bounds, frame share, and the Kit's own
  quad or exact projected conic with its family.
- **yaw**, from −90 (left face) through 0 (front) to +90 (right face).
- **dominant colour** as hue, saturation and lightness.
- **attachments**, each with its own geometry and a free-text descriptor
  (an arched fanlight, a petal ring, a sill).
- **visibility**: occlusion, crop and contrast.

Subjects are windows, doors, buildings, arches, flowers and the Prague T3
tram (the legacy kit's 100 compositions, plus a solid tram at any yaw).
Named test sets:

- `windows-position`
- `windows-aspect-drift`
- `buildings-hue`
- `buildings-pastel`
- `doors-arched`
- `doors-mixed`
- `flowers-petals`
- `tram-yaw`

All take `--seed`, `--count` and `--difficulty` (occlusion, crop, oblique
angle, low contrast, clutter, lighting).

## Run it

```bash
cd ~/Documents/dev/letslapse-generator
python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"      # once; needs librsvg's rsvg-convert
.venv/bin/llgen presets                                         # the test sets
.venv/bin/llgen generate --preset legacy --out out/legacy        # the kit's 100 tram compositions
.venv/bin/llgen generate --preset doors-arched --seed 3 --out out/doors  # a test set
```

`--seed`, `--count`, `--difficulty`, `--scale` (default 2) and
`--orientation 1|6` apply to every preset. The same seed and parameters give
byte-identical output.

## Import its output (from `LetsLapse/`)

```bash
L=Kit/.build/release/lapse                                       # cd Kit && swift build -c release --product lapse
$L shapemation stage <out> --out <projects> --project            # a Photo project per scene; scene.json travels with it
$L shapemation pack <projects>/<set>/* --out <archives>          # one <id>.lapse per project
```

Then double-click a `.lapse`, or launch a Debug Mac build on a scratch root:
`LL_IMPORT_ARCHIVE=<archives>/<id>.lapse <LetsLapse.app>/Contents/MacOS/LetsLapse -ApplePersistenceIgnoreState YES -storage.libraryRootPath <scratch>`.
`stage` refuses a scene whose frame does not read at the record's size, or
whose register does not load back as `subject.family`.

## What in this repository still reads it

- `tools/shapesynth` (perturbation sweeps and scoring) reads the generator's
  `kit/` directly. `--kit` defaults to `$LETSLAPSE_GENERATOR/kit`, else
  `../letslapse-generator/kit` beside this repository. The seeded
  `mixed.random` batch (`recipes_mixed.py`) moved into the generator as
  `llgen generate --preset legacy-mixed`.
- `docs/shapemation/prototype/kit` is a symlink to that same folder
  (`../../../../../letslapse-generator/kit`), and
  `docs/shapemation/prototype-review/run.mjs` reads its `manifest.json`.
- `ShapemationLeastCropTests` inlines numbers taken from the kit's
  `manifest.json`. It does not read the file.

# shapebench — offline shape-detection benchmark

Brief: `docs/shape-benchmark/brief.md`. Findings: `docs/shape-benchmark/report.md`.
Answers one question: is an AI ranking layer needed for photo-mode shape
detection, or do geometric rules suffice (brief §8)?

Everything runs in `tools/.venv` (Python 3.14, numpy, opencv-python-headless,
Pillow, rawpy — no new packages). Outputs land in `tools/shapebench/work/`
(git-ignored). The library under `--root` is only ever read.

## Quick start (from `LetsLapse/`)

```
PY=tools/.venv/bin/python
$PY tools/shapebench/shapebench.py selftest --lapse Kit/.build/release/lapse   # synthetic card, every stage
$PY tools/shapebench/shapebench.py export --root /Volumes/letslapse/Projects   # phase 0: the tagged corpus → work/
$PY tools/shapebench/shapebench.py detect                                      # phase 1: opencv-reference
$PY tools/shapebench/shapebench.py label                                       # phase 2: opens the labelling page
$PY tools/shapebench/shapebench.py metrics                                     # phase 3: opencv vs ground truth
$PY tools/shapebench/shapebench.py vision                                      # phase 4: lapse shapes --json + the library register
$PY tools/shapebench/shapebench.py vision --flags="--sensitivity high"         #   any lapse dial or flag: its own run block
$PY tools/shapebench/shapebench.py metrics --all-runs                          #   every run block of every detector, side by side
$PY tools/shapebench/shapebench.py metrics --docs docs/shape-benchmark         # phase 5: the comparison, copied to docs
```

`detect --params overrides.json` merges a JSON file over `DEFAULT_PARAMS` in
`detect_opencv.py` (`params/dedupe-090.json` is the one tried on 2026-09-11); a different parameter set is a different `paramsHash`, so a
second run block is appended and the first is kept. `--force` replaces that one
key's block only. Nothing is ever flushed (brief §4.1).

## Working directory

```
work/manifest.json               corpus manifest: assets[], labelSet (25 ids, seeded)
work/images/<assetId>.jpg|png    byte copy of the JPEG / rawpy render of a DNG (lossless PNG)
work/register/<assetId>/         byte copy of the library's shapes.json (+ capture_log.json)
work/results/<assetId>.json      schema v2: { schemaVersion: 2, projectId, runs: [...] }
work/vision-raw/<assetId>.<flags>.<lapse sha8>.json   raw `lapse shapes --json` output (provenance; keyed by the binary)
work/labels/<assetId>.json       raw clicks + fit verdicts (audit; GT itself is a run block in results/)
work/logs/<detector>.<hash>.jsonl  one row per candidate region (extent, verdict, reason, scores)
work/overlays/<detector>/        1024-px review pictures; *.vs-gt/ after metrics; combined/ = GT + all
work/metrics.json, work/report-generated.md
```

## Schema v2 in one paragraph

Per project: `runs[]`, each `{detectorId, detectorVersion, paramsHash, params,
runAt, durationMs, assets[]}`; each asset `{assetId, frameWidth, frameHeight,
shapes[], stats}`; each shape `{shapeId, primitive rectangle|ellipse, subclass
square|rectangle|circle|ellipse, centre{x,y}, extentRatio, sizeBand, aspectRatio
≥ 1, orientationDeg ∈ [0,180), vertices|null, axes{major,minor}|null, sizePx,
confidence, maxAngularDeviationDeg, fillRatio, sideMismatch, ellipseIoU,
provenance}`. Coordinates are normalised per axis, origin top-left; `axes` are
full axes as fractions of frame WIDTH (the v1 register's convention). The
`stats` block (candidates, accepted, durationMs) and `provenance` are additive
to the brief's §4.2. `assetId` = project UUID (a Photo project is one asset).

## Detectors

- `opencv-reference` — `detect_opencv.py`: at 1024 and 2048 px, Canny with
  Otsu thresholds (the median-σ heuristic goes blind on bright walls) and the
  adaptive threshold in both polarities, each closed at 5 / 9 / 15 px and each
  paired with a map of everything it encloses (a plate's border broken at a
  rounded corner becomes a solid blob once closing seals it) → contours
  (RETR_CCOMP: a light dial in a dark bezel is a hole) → size/solidity
  prefilter → region dedupe (**this count is "candidates per image"**) →
  full-resolution re-trace inside each ROI → the shared fitting pass. A
  full-res contour replaces the proposal only when its mask IoU with the
  proposal is ≥ 0.8 **and the shape it fits to matches the proposal's own fit
  under the consensus rule** (`fitting.measure`: refinement adds precision,
  never identity — found 2026-09-12 when a 0.93-IoU contour of plate-plus-frame
  replaced a Kit quad that was right to 1.5 % and scored it as a miss);
  otherwise the proposal is measured as traced and the shape carries
  `provenance.refined: false` (and `refineRejected` with the test that failed). Hough-circle proposals and a
  "gather edge points along the rim" refinement were tried and removed: a
  proposal that survives as its own outline scores IoU 1.0 by construction,
  and a band around any circle on a textured facade collects edge points at
  60 % of angles — both fake a measurement.
- `apple-vision` — `lapse shapes <image> --json` (the shipping Kit detector at
  its Find-shapes defaults); each v1 shape becomes a region prior, is re-traced
  at full resolution and measured by the same pass. Candidates = shapes +
  diagnostics' `quadsOffered + ellipseFits + rimPeaks` (its refusal list is
  trimmed to 24, so it is not a count). Note: when no full-res contour matches
  a Vision ellipse at IoU ≥ 0.8 the proposal stands as its own outline and
  its IoU is ~1 by construction (`provenance.refined: false`; the report
  counts these as "measured as proposed"); Vision quads that are trapezoids
  are rejected by the image-space rule *by design* and are reported as such,
  not as bugs.
- `apple-vision-register` — the library's own `shapes.json` (v1), same
  conversion, with `provenance.v1Source` = captured (kept by the shooter on
  the viewfinder) / detected / manual.
- `manual-groundtruth` — the labelling page. Rectangle = 4 corner clicks taken
  as vertices (the §3.4 checks are recorded in `gt.passesRules`, never used to
  reject: a human-labelled trapezoid is still a target). Ellipse = ≥ 5 rim
  clicks, fitted by the same direct least-squares fit; RMS residual must be
  ≤ 1 % of the axis. Shapes under the size floor are kept, banded `discard`;
  the metrics stage applies the floor to labels and detections alike.

## The shared fitting pass (`fitting.py`)

Native pixels, upright, y down. Rectangle: `approxPolyDP` at 2 % of the arc
length → 4 vertices, convex, interior angles 90 ± 8°, opposite sides within
10 %, `fill = contourArea / minAreaRect area ≥ 0.85`; aspect/orientation from
`boxPoints` (never `minAreaRect`'s angle — its range differs by OpenCV
version). Ellipse: `fitEllipseDirect`, mask IoU on a local ROI ≥ 0.90,
minor/major ≥ 0.40; circle at ≥ 0.95; square at aspect ≤ 1.05. Fill ratio and
ellipse IoU are both IoUs of the contour against a fitted primitive, so "the
better fit wins" compares them directly. Size band from the fitted primitive's
axis-aligned bbox, applied after fitting so the size floor can be re-swept from
the candidate log without re-running.

Matching (metrics): same primitive, centre offset ≤ 2 % of the diagonal, mask
IoU ≥ 0.70 at a 1024-px working scale, aspect within 10 %; greedy one-to-one
by IoU.

## Labelling page keys

`R`/`E` primitive · click points · `Enter` fit & keep · `Backspace` undo point
· `Esc` clear · `Delete` remove the selected shape · `D` done (saves, jumps to
the next unlabelled) · `N`/`P` next/previous · wheel zoom at the cursor · drag
to pan · `0` fit · `1` 1:1. A loupe follows the cursor. Every kept shape is
saved at once; "done" with no shapes is a valid label (the picture then counts
for false positives).

## DNG note

The four DNG assets are rendered once by rawpy (`use_camera_wb`,
`no_auto_bright`, the file's own flip) to lossless PNG, and *both* detectors
read that PNG — `lapse` takes ~35 s on a native DNG (ImageIO raw decode) and
~1 s on the PNG, and the geometry is the same picture either way. Dimensions
are asserted against `library.json` at export and against `lapse`'s own
`width/height` at every vision run.

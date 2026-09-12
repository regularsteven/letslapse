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
$PY tools/shapebench/shapebench.py gt-import --source docs/shape-benchmark/labels   # a fresh work/: ground truth back from git
$PY tools/shapebench/shapebench.py detect-one --detector edge-drawing --image <file>   # one picture → the Kit's shape JSON (the Mac app's Python engines)
<contrib venv>/python tools/shapebench/shapebench.py ed [--params f.json] [--dry]    # edge-drawing detector (needs cv2.ximgproc)
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
                                 (archived in docs/shape-benchmark/labels/; `gt-import --source <dir>` rebuilds them and the GT run blocks)
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

`detect-one` is how the Mac app's "Python reference" / "Python edge drawing"
detection modes run (`App/Shapemation/ExternalShapeDetector.swift`, Settings ▸
Advanced points the app at this `tools` folder): one picture, one detector,
the shapes printed as the Kit's own `DetectedShape` JSON (`fitting.shape_to_v1`).
Since 2026-09-12 the venv carries `opencv-contrib-python-headless` (a superset
of the plain wheel) so `edge-drawing` runs in it too.

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
- `edge-drawing` — `detect_ed.py` (2026-09-12 review, `shapebench.py ed`): EdgeDrawing
  (`cv2.ximgproc`, parameter-free mode) at 1024 / 2048 / native; closed edge chains become
  regions (a native-scale chain is its own full-resolution measurement), EDCircles' ellipse
  hypotheses are re-traced like Vision's, optionally gated on native edge support
  (`ellipses.minEdgeSupport`, 0.7 is the precision setting) or `requireRefined`; then the
  shared pass. Needs `opencv-contrib-python-headless` in place of `opencv-python-headless`
  (a superset — uninstall the plain wheel first, one `cv2` only); `ed` refuses to run without
  `cv2.ximgproc`. `--dry` scores against the labels and writes overlays without a run block.
  Measured: 74 / 46 alone, 97 of 153 in union with the Kit —
  `docs/shape-benchmark/review-2026-09-12.md`. The `quads` block (rectangles from EDLines
  segments) is off by default: both forms tried buy hits only at a wall of false positives on
  tiles and cobbles (§5 of the review).
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

The `apple-vision` and `apple-vision-register` blocks are scored as the Kit emits them: no
second dedupe after refinement (`v1Dedupe: none` in their run params since 2026-09-12 — the
consensus dedupe at 0.9 was merging two Kit shapes 5–10 % apart once the full-resolution
re-trace had pulled both onto one contour, hiding five true positives). The reference and
edge-drawing detectors still dedupe their own output (`shapeDedupe`).

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

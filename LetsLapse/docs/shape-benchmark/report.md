# Shape detection benchmark — findings

**Run:** 2026-09-11, macOS, M4 Max, against the 37 "Shape testing" Photo projects in the Mac
library at `/Volumes/letslapse` (33 JPEG + 4 DNG, all 12 MP). Ground truth: Steven hand-labelled
the 25-picture label set the same evening — 76 shapes, 68 above the 0.10 size floor (26 circles,
16 ellipses, 10 squares, 24 rectangles; 47 small / 16 medium / 5 large).
**Tool:** `LetsLapse/tools/shapebench` (Python in `tools/.venv`, read-only on the library).
Raw outputs — every candidate region with its verdict, per-run overlays, the `lapse` JSON — are in
`tools/shapebench/work/` on this Mac (git-ignored, ~250 MB); this folder carries the brief, this
report, the generated tables (`report-generated.md`, `metrics.json`) and the 25 review pictures
(`review/`, green = label, cyan = matched, orange = false positive, red = miss).

## Verdict

- **No AI ranking layer for photo mode (brief §8).** The geometric reference accepts a median of
  **2 shapes per picture** (p25–p75 1–4, max 9) out of a median 216 candidate regions. The §3 rules
  and the 0.10 size floor *are* the salience filter: even at full recall the figure would sit near
  3–4, well under the gate's 6. Tightening the floor (0.15–0.25) only moves the median to 1.
- **The problem is finding, not choosing.** When the reference finds a labelled shape its geometry
  is as good as the labels: aspect error median 1.6 % (p95 7 %), centre offset median 0.11 % of
  the diagonal (p95 0.36 %), orientation error median 0.3°, and 33 of 38 matches carry the same
  subclass the labeller chose. But it finds only **56 %** of the labels (38 of 68), at 61 % precision.
- **The shipping Vision path finds far less.** `lapse shapes` (the Find shapes defaults) proposes
  36 shapes across the 25 labelled pictures; measured through the same pass it hits 11 labels
  (recall 16 %, precision 44 %). Taken exactly as proposed, with no refinement at all, it hits 14
  (recall 21 %). The library's own registers, which include the shapes the shooter left standing
  on the viewfinder, reach 23 % (30 % as proposed); the shooter-kept `captured` shapes are twice as
  precise as the file pass's `detected` extras (10/22 vs 4/20 true).
- **The reference agrees with a person on what a shape is; it disagrees on how many there are.**
  Phase 3's bar ("the OpenCV reference agrees with the labels") is met for measurement and not for
  recall. That is the finding, and it points the next work at proposal, not at rules or ranking.

## Numbers

| detector | labelled | labels ≥ floor | TP | FP | FN | precision | recall | aspect err med / p95 | centre offset med / p95 (% diag) | accepted / picture med (p25–p75, max) | candidates / picture med | s / picture |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| opencv-reference `5cc92beb0d6e` | 25 | 68 | 38 | 24 | 30 | 61 % [49–72] | 56 % [44–67] | 1.6 % / 7.1 % | 0.11 / 0.36 | 2 (1–4, 9) | 216 | 3.3 |
| apple-vision (`lapse shapes`, Find-shapes defaults) | 25 | 68 | 11 | 14 | 57 | 44 % [27–63] | 16 % [9–27] | 1.0 % / 3.4 % | 0.07 / 0.38 | 1 (0–1, 5) | 89 | 1.0 (+decode) |
| apple-vision-register (library `shapes.json`) | 22 | 61 | 14 | 28 | 47 | 33 % [21–48] | 23 % [14–35] | 1.4 % / 6.2 % | 0.11 / 1.71 | 1 (1–3, 4) | — | — |

Brackets are Wilson 95 % intervals. Matching is the brief's consensus rule (same primitive, centre
within 2 % of the diagonal, mask IoU ≥ 0.70, aspect within 10 %), greedy one-to-one by IoU.
Vision's candidate count is the Kit's own `quadsOffered + ellipseFits + rimPeaks`. Runtime for
Vision is the Kit's `diagnostics.milliseconds` (excludes the ImageIO decode); one cobble picture
took 57 s in the Kit's Hough pass on the Mac. The reference is unoptimised Python at two proposal
scales × three closing sizes × five maps.

Reference recall by class: ellipses 49 % (18/37), rectangles 65 % (20/31); small 53 %, medium 62 %,
large 60 %.

## Where the misses and false positives come from

Read off the 25 review pictures and the candidate log (every rejected region carries the gate it
failed and its scores):

1. **Concentric and nested shapes** — a sign's red rim and its inner disc, a tyre / rim / hubcap,
   a manhole ring and lid, a window frame and its pane. The labeller marked both; the detector
   finds one. Several of the false positives are the *other* member of such a nest (the pane where
   the label is the frame, the hubcap nobody labelled). Note that the brief's own consensus rule
   calls two rings 8 % apart in radius "the same shape" (IoU 0.85): four of the label pairs match
   each other under it, so it cannot resolve nests either way.
2. **Ornate, ribbed or textured rims** — rose windows, the oval window in its stone surround,
   the sunburst medallion at a distance, the radiator valve's ribbed ring, the dark doorbell
   buttons. These are proposed (a region is there) but the traced contour is not clean: ellipse IoU
   0.50–0.86 against the 0.90 gate, or 5–12 vertices where a rectangle needs 4. Seven labels were
   never proposed at all.
3. **Small legitimate rectangles the labeller did not mark** — facade windows, a date plate, a
   pictogram box, an arrow plate. These are the bulk of the remaining false positives and are
   exactly the §8 question: they are valid shapes, not the target a person meant. At 2 accepted
   shapes per picture they are a picker problem, not a ranking-model problem.
4. **Trapezoids by design** — 8 of Vision's 36 proposals and 16 of the registers' 63 are oblique
   quads (the app keeps them and rectifies their aspect from the lens); the image-space rule
   rejects them, as the brief intends. They are reported as "rejected: oblique quad", not as
   false positives.

## The one tune (brief §7, phase 3)

Tried: within-detector dedupe at IoU 0.90 instead of the consensus 0.70, to keep concentric rings
apart (run `6114968f7c78`, kept beside the pinned run in every results file). Result: +1 true
positive, +11 false positives (a thick edge traced on both sides becomes two rings). Rejected; the
first run stays pinned. Also read from the candidate log without re-running: relaxing the ellipse
IoU gate to 0.85 buys 4 labels for 7 false positives, to 0.80 buys 14 for 49; a 0.03
`approxPolyDP` epsilon (rounder corners) buys 0 for 26; rectangle fill 0.80, sides 15 % and angle
12° buy 0–1. **The §3 thresholds stand as specified.**

## Dial sweep (2026-09-11, later): the missing recall is not behind a setting

Step 1 of "Next" below, done the same night: the shipping detector run through the rig at every
sensitivity and at the Small size dial, each as its own run block, all against the same labels.

| `lapse shapes` dial | raw shapes on the 25 | TP | FP | FN | precision | recall |
|---|---|---|---|---|---|---|
| all / **medium** / all (Find-shapes default) | 36 | 11 | 14 | 57 | 44 % | 16 % |
| all / high / all | 63 | 13 | 33 | 55 | 28 % | 19 % |
| all / low / all | 22 | 11 | 5 | 57 | 69 % | 16 % |
| all / medium / small | — | 4 | 8 | 64 | 33 % | 6 % |
| all / high / small | — | 4 | 41 | 64 | 9 % | 6 % |

- **High** doubles the proposals and buys 2 labels for 19 more false positives. **Low** keeps the
  default's recall exactly and drops 9 of its 14 false positives: on this corpus the medium default
  pays nine false positives for nothing.
- 17 of the 68 labels have a major axis under the Kit's own size floor (1/6 of the short edge,
  504 px on these frames, versus the brief's 0.10 of the frame). The Small dial, which covers that
  band, finds 4 of them at 8–41 false positives — the floor is not the cause; those shapes are not
  proposed.
- **Union over every Vision setting and the phone registers: 19 of 68 labels.** The geometric
  reference alone: 39. Both together: 43. **25 labels are found by nothing** — 8 small rectangles,
  6 small circles, 4 small ellipses, 2 medium circles, 2 medium rectangles, 2 large ellipses, 1 small
  square. 24 labels are found by the reference and by no Vision setting; 4 the other way.

So the Kit's proposal stage is the bottleneck, and it is not a dial. The reference's contour maps
(Otsu-threshold Canny with an enclosed-fill pass at three closing sizes, RETR_CCOMP so a light
shape inside a dark one is a hole) find twice as many of the shapes a person marked. The
actionable step is to port those maps into the Kit's still-photo pass as an extra candidate
source — the file pass has seconds to spend, the live pass does not — and re-run this benchmark.
The 25 never-found labels are the hard set to watch.

## The port (2026-09-12): the reference's proposal maps in the Kit's still-photo pass

Step 1 of "Next" as it stood after the dial sweep. `Kit/Sources/LetsLapseKit/Shapes/RegionProposals.swift`
is the reference's proposal stage in Swift, no OpenCV: the 5-tap Gaussian, Canny with thresholds
from the picture's Otsu split, the Gaussian-mean adaptive threshold in both polarities (block 51,
C 5), closings at 5 / 9 / 15 px with disc kernels, the enclosed-interiors map, contours with holes
(a Moore tracer over labelled components), then the §3 fits — minimum-area rectangle with fill ≥
0.85, corners within 8° and opposite sides within 10 % after an `approxPolyDP`-faithful
simplification; ellipse by direct least squares with polygon IoU ≥ 0.90 and axis ratio ≥ 0.4.
It runs after the Vision passes and is admitted where they found nothing; `live` turns it off.
Cost: ~250 ms per picture at 1024 px on an M4 Mac, ~1.2 s at 1024 + 2048 (the Vision passes
themselves are 0.3–23 s). Every configuration below is a run block against the same 68 labels.

| Kit still-photo pass (`lapse shapes`) | TP | FP | FN | precision | recall | small / medium / large recall |
|---|---|---|---|---|---|---|
| as shipped (medium, SIZE floor 1/6 short edge + 400 px) | 13 | 15 | 55 | 46 % | 19 % | 5/47 · 6/16 · 2/5 |
| + region pass @1024 | 16 | 16 | 52 | 50 % | 24 % | 7/47 · 7/16 · 2/5 |
| floor 0.10 of the short edge, no region pass | 22 | 13 | 46 | 63 % | 32 % | 13/47 · 7/16 · 2/5 |
| floor 0.10 + region pass @1024 | 26 | 15 | 42 | 63 % | 38 % | 16/47 · 8/16 · 2/5 |
| **floor 0.10 + region pass @1024 + 2048** | **31** | **25** | **37** | **55 %** | **46 %** | 20/47 · 8/16 · 3/5 |
| floor 0.10 + region pass @1024, sensitivity low | 22 | 14 | 46 | 61 % | 32 % | 14/47 · 7/16 · 1/5 |
| geometric reference (Python, for scale) | 39 | 21 | 29 | 65 % | 57 % | 26/47 · 10/16 · 3/5 |

(The "as shipped" row reads 19 % here against 16 % in the tables above because of the measurement
fix below; both are the same detector.)

Three findings, in the order they were found:

1. **The rig's refinement was changing what it measured.** A Kit quad on the enamel plate was
   right to 1.5 % in aspect; the rig's full-resolution re-trace replaced it with a 0.93-IoU
   contour of plate-plus-frame, 12 % off in aspect, and scored a miss. Refinement now keeps the
   proposal's verdict unless the refined shape matches it under the consensus rule
   (`fitting.measure`). Every block above is re-measured under that rule; the reference moved
   from 38/24 to 39/21, the shipping pass from 11 to 13 hits.
2. **The Kit's size floor costs nine labels for nothing.** SIZE = All means a diameter of at
   least 1/6 of the short edge and 400 px; 17 of the 68 labels are smaller. At 0.10 of the short
   edge (the brief's floor) the unchanged Vision machine finds 22 instead of 13, with two
   *fewer* false positives.
3. **The region pass is worth 4 labels at 1024 and 9 at 1024 + 2048** on top of that, for +2 and
   +12 false positives. What it adds is what the reference added: the sunburst medallion, a bell
   button, a small round sign, window frames, plates. The 25 false positives of the two-scale
   run are 15 nested members (the inner ring, the pane inside the frame — the same nests you
   labelled elsewhere), 9 unlabelled small facade windows, and one phantom circle on a street.
   Two details the port needed that the Python did not: a rectangle's polygon must be
   simplified the way `approxPolyDP` does it (drop any vertex within ε of its neighbours'
   chord, or a seed point on a straight side is a fifth corner), and a region's outline must
   lie on edges — the Gaussian-mean threshold turns any large flat region into a blob whose
   boundary sits ~2σ (16 px) inside the real edge, which at 1024 px fits a perfect circle of
   the wrong size (`minOutlineEdgeSupport`).

Reach: every Kit configuration together finds 37 of 68, the reference 39, both 46; 22 labels
are found by nothing (7 small rectangles, 5 small circles, 3 medium circles, 3 small ellipses,
2 large ellipses, 1 medium rectangle, 1 small square). The reference still has 9 labels no Kit
run reaches (6 never proposed by any map at either scale, 2 refused by the Kit's own Hough gates
within a hair — support 0.33–0.34 against 0.35, coverage 0.53 against 0.55 — and one plate
whose contour merges with its bracket); the Kit has 5 the reference lacks.

### Nest policy: flat (decided 2026-09-12)

Steven's call: **every member of a nest the passes can measure is a shape in the register**
(the sign's rim *and* its disc, the tyre *and* the rim *and* the hubcap), and whoever needs one
target per object takes the biggest — which the Shape-mation builder already does (admissible
shapes sorted largest-first, the first one picked). What flat changed is upstream: four merge
rules in the Kit and one in the reference were written to kill one edge traced twice and were
collapsing nests as a side effect — the Kit's bounds-IoU 0.5 dedupe merged rings up to 30 % apart
in radius and kept whichever scored higher, not the outer one. "The same shape" is now
near-identical only (`ShapeDetector.sameShapeIoU` 0.9, radii within ~5 %; the Hough pass still
merges an off-centre near-copy as a lobe vote; the reference's `shapeDedupe` 0.9). Scoring stays
per label, and the tables now carry a second precision reading that leaves out false positives
nested inside a labelled shape — under flat those are labels nobody drew, not detector errors.

| flat merging | TP | FP | FP nested in a label | precision strict / excl. nested | recall | accepted / picture med (max) |
|---|---|---|---|---|---|---|
| Kit as shipped (no region pass, SIZE floor 1/6) | 14 | 21 | 13 | 40 % / 64 % | 21 % | 1 (7) |
| **Kit + region pass @1024 + 2048, floor 0.10** | **39** | 38 | 20 | 51 % / 68 % | **57 %** | 3 (26) |
| reference, `shapeDedupe` 0.9 | 40 | 31 | 21 | 56 % / 80 % | 59 % | 2 (13) |

The Kit's still-photo pass now finds what the Python reference finds — 39 of 68 against 40 —
and the remaining precision gap is the members you did not label (20 of 38) and the small facade
windows (most of the other 18). The §8 gate holds: median 3 accepted per picture; the facade
picture with two window rows is the 26. To score flat fairly the label set wants a completion
pass — open each picture, add the inner members you agree are targets; the tool's drag points
make that a few minutes — after which the "excl. nested" column becomes the strict one.

### The completed label set (2026-09-12 evening)

Steven completed the nests and went further: every one of the 37 pictures is now labelled (the 12
outside the original set too), older shapes were redrawn where they had been placed loosely, and
the set stands at **105 shapes, 92 above the floor in the 25-picture set, 153 above the floor over
all 37** — 111 small, 31 medium, 11 large. Every block is scored against that set from here on;
the tables above keep their 68-label numbers as history.

| flat merging, 37 pictures, 153 labels | TP | FP | FP nested in a label | precision strict / excl. nested | recall | small / medium / large recall |
|---|---|---|---|---|---|---|
| Kit as shipped (no region pass, SIZE floor 1/6) | 26 | 30 | 18 | 46 % / 68 % | 17 % | 14/111 · 10/31 · 2/11 |
| **Kit, new default: region pass @1024 + 2048, All floor 0.10** | **72** | 66 | 32 | 52 % / 68 % | **47 %** | 50/111 · 15/31 · 7/11 |
| reference, `shapeDedupe` 0.9 | 66 | 43 | 24 | 61 % / 78 % | 43 % | 43/111 · 16/31 · 7/11 |

The Kit's still-photo pass now finds more of what a person marks than the Python reference it was
ported from (72 against 66), at lower precision (52 against 61 %); the redrawn labels show in the
geometry — aspect error median 1.1 %, centre offset 0.10 % of the diagonal. Recall reads lower
than the 57 % of the 68-label set because 85 of the 85 added labels are the hard kind: 111 of 153
are small. The §8 gate holds at a median of 2–3 accepted shapes per picture. SIZE = All's file-pass
floor is 0.10 of the short edge with no pixel minimum from this point (`ShapeSearch.Size.fileFloor`;
the viewfinder keeps 1/6).

**State of the Kit change (uncommitted):** the region pass is on by default in the file profile at
1024 + 2048 and off in `live`; SIZE = All's file floor is 0.10; merging is near-identical only (flat); `lapse shapes` gained `--regions / --no-regions`,
`--region-edges A,B`, `--floor F` (an experiment's floor) and `--region-gates loose`;
`ShapeDetector.Diagnostics` carries `regionMaps / regions / regionsKept` and decodes registers
written before them. Tests: `RegionProposalsTests` (maps, tracing, fits, IoU, the hole case,
the trapezoid refused, old diagnostics decode). Both decisions are made: the floor is 0.10 and the nest policy is flat.

## In the app (2026-09-12, Mac, Release build)

The same comparison run where it ships: the Mac app's **Find shapes** over the 37 Shape testing
projects, registers reset so they would be re-analysed (originals backed up), the rewritten
`shapes.json` files scored against the same labels through the rig's register block. Two runs, the
second after two fixes the first one surfaced.

| library registers, 37 pictures, 153 labels | TP | FP | of which nested | precision strict / excl. nested | recall | median s / project |
|---|---|---|---|---|---|---|
| before (old detector; the phone's captured shapes + its file pass) | 25 | 35 | 11 | 42 % / 51 % | 19 % (of 132 on 33 pictures) | — |
| after the port, in-app run 1 | 66 | 65 | 28 | 50 % / 64 % | 43 % | 3.1 |
| **after the port, in-app run 2 (captured shapes snapped)** | **71** | 72 | 33 | 50 % / 65 % | **46 %** | 2.8 |
| the CLI on the same files, DNGs decoded as the app does | 69 | 64 | 31 | 52 % / 68 % | 45 % | 2.9 |

So in the app itself: **19 % → 46 % of the shapes a person marked**, precision 42 % → 50 % strict
(51 % → 65 % leaving out unlabelled nest members), 39 projects in 4 min 50 s on an M4 Max. The
p90 of 19 s and the 58 s maximum are the Kit's existing Hough pass on cobbles and facades, not the
new code; the new pass costs ~1.2 s of the 2.8 s median. Of the 71 hits, 17 are shapes you kept on
the viewfinder at capture time and 54 are the file pass's; of the 72 false positives, 12 are old
viewfinder shapes that match no label and 60 are detections, 33 of those nested inside a label.

What the run surfaced, all fixed in the tree:

- **Find shapes was not running the file profile.** It built `ShapeDetector()` from raw defaults
  (floor 1/6 + 400 px) and decoded the picture at 1024 px, so the 2048 region scale would have
  run on a 1024 image. It now uses `ShapeSearch().fileSettings()` and decodes at
  `Settings.decodeLongEdge`; the capture-time path decodes at the same.
- **Captured viewfinder shapes kept their 384-px geometry** and the sharper file detection of
  the same object was dropped. Find shapes now snaps a captured shape to its file fit (identity,
  name and `captured` source kept) at a still-against-still bar of bounds-IoU 0.7
  (`ShapeReconciler.stillMatchThreshold`; the viewfinder's own 0.4 is drift tolerance and stays);
  a hand-drawn shape still wins over its detection. Worth 5 hits here.
- **A re-analysis dropped the viewfinder trail** (the register was rebuilt without it). Carried
  over now.
- **DNGs are a slightly different picture in the app.** The app (CIRAWFilter) and `lapse`
  (ImageIO) decode raw at the detector's size straight from the file; the rig rendered the full
  frame and downsized. The pixels differ by 2.5 levels on average and the P-sign's two squares,
  right at the size floor, flipped on it. The rig now hands `lapse` the DNG itself for DNG assets
  (`stats.lapseInput`) and renders its own reference frames through ImageIO rather than rawpy.
- The Mac target had not built since yesterday's field-test commit (two iOS-only symbols
  outside their guards in `CameraController`). Fixed.
- `ShapeRegister.detectorVersion` exists for exactly this re-analysis but Find shapes only
  checks the analysed flag; 199 registers in this library carry version 1. Bumping the version
  and re-analysing older registers is the release step, deliberately not done for the test.

## What was learned building the reference (worth keeping)

- The brief's auto-Canny (median ± σ) goes blind on a bright wall (median 165 → high threshold
  220 — the enamel plate's border vanishes). Thresholds from the Otsu split of the picture work
  everywhere in this corpus.
- Edge rings break at rounded corners. An enclosed-fill map (flood the background, invert) at
  three closing sizes turns a plate whose ring is broken at one corner into a solid blob. No single
  closing size works: 15 px finds the plate, 9 px the medallion.
- Hough-circle proposals and a "gather edge points along the rim" refinement were built and
  removed: a proposal that survives as its own outline scores IoU 1.0 by construction, and a band
  around any circle on a textured facade collects edge points at 60 % of angles. Both fake a
  measurement. The same trap applies to Vision's ellipses: when no full-resolution contour
  matches one at IoU ≥ 0.8 it stands as proposed and its IoU means nothing — 21 of Vision's 39
  accepted shapes and 39 of the registers' 56 are in that state (`provenance.refined: false`).
- Refinement must not veto proposals. At a 0.6 replacement threshold the tracer's messier contours
  rejected 35 register ellipses that a person would keep; at 0.8 the label set is the judge.

## Caveats

- 25 pictures, 68 labels: precision and recall resolve to about ±12 points (the intervals above).
  Per-class rows have n < 10 in places; read them as counts.
- The corpus was shot *at* targets, one clear subject per frame. Candidates per picture on a
  random street picture would be higher; the size floor, not this corpus, is what keeps it low.
- DNGs were measured on a rawpy render, not the app's ImageIO render (same geometry, different
  demosaic); `lapse` was run on that PNG too (35 s on the native DNG, 1 s on the PNG).
- The register blocks are 1024-px proposals from the phone, refined locally here; their
  "detected" shapes are the app's older Find-shapes output, not today's.
- Labels were made in one sitting with the rig's own page; nested shapes were labelled when the
  labeller thought of them, which is not consistent across pictures.

## Next

1. ~~Port the reference's proposal maps into the still-photo pass~~ — done; in the app 19 % → 46 %
   of the labels. ~~Decide the SIZE floor, complete the labels, run it in the app~~ — done.
   Remaining: bump `ShapeRegister.currentDetectorVersion` so libraries re-analyse (Find shapes
   should treat an older version as to-do), then a phone run for time and heat.
2. The Kit's Hough rim gates refuse two labelled rings by 0.01–0.02 (support 0.33/0.34 vs 0.35,
   coverage 0.53 vs 0.55); a benchmark run at 0.30 / 0.50 would say whether that is a free
   two labels or a wall of arches. Cheap: `--flags` on `vision`, one run block.
3. Six labels are never proposed by any map at either scale — the small dark buttons and the
   inner panes. Those need a different idea, not a tuned threshold.
2. **Adopt schema v2 in the app** (TODO "Shape register schema v2"): the run ledger, the §3 rules,
   the size bands, and `refined`/provenance are the pieces Find shapes needs.
3. **Decide the nest policy** once: label and detect the outermost member, or all members. The
   consensus rule needs a concentric-aware test either way.
4. Re-label 10 more pictures blind (a second labeller or the same one a week later) to price the
   labelling noise before trusting differences under ~10 points.

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

1. **Proposal, not rules.** The recall gap is ornate rims and nests. The Kit's own Hough rim pass
   finds the rose windows and medallions that this reference cannot trace — measured honestly
   (edge support with radial gradient agreement, not a band), it is the candidate to lift recall.
   Benchmark it as another run block against these labels; it earns its place or it does not.
2. **Adopt schema v2 in the app** (TODO "Shape register schema v2"): the run ledger, the §3 rules,
   the size bands, and `refined`/provenance are the pieces Find shapes needs.
3. **Decide the nest policy** once: label and detect the outermost member, or all members. The
   consensus rule needs a concentric-aware test either way.
4. Re-label 10 more pictures blind (a second labeller or the same one a week later) to price the
   labelling noise before trusting differences under ~10 points.

# Shape Sequence spike — findings

**Run:** 2026-09-10, macOS, M4 Max, against the Mac library at `/Volumes/letslapse`
(186 captures in `library.json` at scan time — 109 at the start of the session,
77 Photo-mode street shots from the iPhone 16 Pro were imported to the Mac the same
day and are the reason there is any shape material at all).
**Tool:** `LetsLapse/tools/shapeseq` (Swift package, Apple frameworks +
`swift-argument-parser`, read-only on the catalogue). Raw outputs — every candidate,
every clip, the full run log — are in `tools/shapeseq/spike-out*/` on this Mac
(git-ignored, ~750 MB); this folder carries the report, the machine-readable
groups, and downscaled review sheets.

## Verdict

**The catalogue does not support a "mine what exists" Shape Sequence feature. The
alignment maths does produce a held shape, and it is worth watching — for circles,
for six or seven items, with two of the brief's render rules changed.**

- **Detection finds real anchors, not noise, but misses half of the obvious ones.**
  Every accepted ellipse is a genuine circle (two road signs, a building clock, a
  stone rosette, a traffic-light lens, an oculus). Of 13 obvious circles a person
  can point at on the contact sheets, 6 are found at the brief's gates (46 %
  recall, 100 % precision). The misses are textured circles — the Gros-Horloge dial
  in four shots, two cathedral rose windows, a round mirror — whose contour is
  jagged, not absent. One parameter decides it: the 3 % radial-residual gate. At
  4 % the Gros-Horloge joins with no false positive; at 5 % one borderline plane
  window joins; from 6 % river panoramas start passing and precision collapses
  (table below).
- **There is not enough co-shaped material for a sequence of meaningful length.**
  Ellipses: one viable group of 6 (7 at the 4 % gate), all head-on. Quads: 58
  assets, groups of 6–30 — but a quad here is almost always a window on a façade,
  seldom the subject, and the rectangle detector adds blank-sky and night-shadow
  false positives. **None of the interval shoots — the LetsLapse-native material,
  79 of 172 — carries a usable circle.** The shape material is entirely in the
  imported stills.
- **The aligned result reads as a held shape — under two conditions the brief did
  not anticipate.** (1) The brief's "rotate the major axis to horizontal" rule
  spins near-circular anchors by an arbitrary angle (a sign at obliquity 1.00 came
  out 70° off, a traffic light on its side): the axis direction of a circle is
  noise. With rotation off, the seven-circle clip reads exactly as intended
  (`review/ellipse-group-gate04-centred-then-aligned.jpg`). (2) Twelve-megapixel
  portrait sources shrunk so a large shape sits at 40 % of a 1080-row landscape
  frame never fill the frame: the default `exclude` edge policy dropped 294 of
  344 item-renders (85 %). Letterboxing is not optional on this catalogue; a
  portrait output frame is the natural fix (variant rendered).
- **Un-skewed versus centred is not settled.** Every accepted circle is head-on
  (obliquity 0.94–1.00) except the oculus at 0.84, so the two variants are
  visually identical on the control group and differ mildly on one item. The
  catalogue lacks oblique circles; the question needs shot-for-purpose material.
- **The resolution budget is a non-issue here.** Every scale factor is below 1
  (0.17–0.89): nothing is upscaled, because the shapes that pass the 400 px gate
  in 12 MP stills are already larger than the 432 px target.

What this points at: the feature is a **"shoot for it deliberately"** workflow —
the armed viewfinder detecting the circle live (the `ShapeDetectionService` here,
with a `CVPixelBuffer` overload), a portrait frame, and no rotation — rather than a
catalogue miner. The maths is done; the month would go on capture UX and on
detection recall for textured circles, and its value depends on people shooting
circles on purpose.

## What was run

| stage | what |
| --- | --- |
| inventory | `library.json` captures + blends, plus a folder walk for unlisted directories; one representative image per shoot (blend image → mid frame of a blend clip → middle rendered frame → RAW decode last) |
| detect | 1024 px long edge; quads via `VNDetectRectanglesRequest` (aspect ≥ 0.3, ≤ 12 observations, confidence ≥ 0.6, quadrature 30°); ellipses via `VNDetectContoursRequest` × (dark-on-light, light-on-dark) × contrast 1/2/3, plus two passes over a Core Image edge map (CIEdges → threshold 0.06 / 0.15 → dilate); polygon-approximation reject; Halir–Flusser direct least-squares conic fit; gates as the brief specifies |
| group | by kind, then obliquity bucket (and width/height bucket for quads); minimum 4, near-misses of 3 reported, cap 30 by confidence; chronological + size-ordered |
| render | 1920×1080 H.264 30 fps, 1 s per item, hard cuts, burned caption; centred and aligned variants; passes: brief default (`exclude`, rotation `major`), `letterbox` + rotation `none`, a portrait 1080×1920 variant, and a 4 %-gate variant of the ellipse groups |

Self-test (`shapeseq selftest`): a synthetic 3000×2000 card with a 25°-rotated
ellipse and a perspective quad. The fit recovered centre (1000.3, 800.2) for
(1000, 800), semi-axes 500.2/300.3 for 500/300, rotation 24.98° for 25°; the
render transforms put the anchor centre at (960.0, 540.0).

## Inventory

| | count |
| --- | --- |
| captures in `library.json` at scan | 186 (plus 3 unlisted folders) |
| shoots with a representative image | **172** |
| · stills (Photo mode) | 93 |
| · interval shoots | 79 |
| · representative from a rendered blend image | 10 |
| · from the mid frame of a rendered blend clip | 38 |
| · from a rendered source frame | 18 |
| · from a RAW decode (DNG/ARW, `CIRAWFilter`, logged) | **106** |
| unlisted folders used | 2 (one skipped as video) |
| skipped: video-mode source | 16 |
| skipped: no representative (750 of 750 listed files absent) | 1 |
| detector failures | 0 |

RAW decode is the majority path because most stills and many DNG interval shoots
have no rendered output. Draft-mode `CIRAWFilter` decodes are grainy — up to
16 000 contours per image — and one unlisted DNG folder (`5968F261`) decodes with
a magenta cast (no colour matrices in the file, presumably). Detection time per
asset: median 2.4 s, max 29 s under contention (see "tooling findings").

## Detection

| | ellipse | quad |
| --- | --- | --- |
| assets with ≥ 1 accepted anchor | **6** | **58** |
| accepted anchors before one-per-asset | 6 | 92 |
| candidates recorded (past the bounding-box prefilter) | 8 267 | 261 |

Rejection breakdown, ellipses (8 261): residual 7 392 · polygonal 856 · duplicate
13. Coverage, obliquity, size and border gates rejected nothing that had passed
residual — the residual gate is doing all the work. Quads (169): too-small 165 ·
duplicate 4.

### Hand-labelled circles (from the contact sheets)

| asset | what | native ⌀ px | best residual | coverage | at 3 % | at 4 % |
| --- | --- | --- | --- | --- | --- | --- |
| 5CEC7AA7 | no-stopping sign | 879 | 0.001 | 1.00 | ✓ | ✓ |
| BFB1B44A | building clock | 531 | 0.005 | 1.00 | ✓ | ✓ |
| 3F70171F | stone rosette | 1386 | 0.006 | 1.00 | ✓ | ✓ |
| 8898B1D5 | traffic-light lens | 520 | 0.008 | 1.00 | ✓ | ✓ |
| 41EADF93 | no-entry sign | 1245 | 0.013 | 1.00 | ✓ | ✓ |
| C864BBD7 | oculus above a doorway | 535 | 0.027 | 1.00 | ✓ (edge pass) | ✓ |
| 7F542709 | Gros-Horloge dial, close | 892 | **0.040** | 0.97 | ✗ | ✓ |
| B22A3F8D | round mirror on a striped pole | 740 | 0.050 | 0.81 | ✗ | ✗ |
| 36E1B1C2 | rose window in a pointed arch | 1685 | 0.065 | 0.56 | ✗ | ✗ |
| 1F14548B | Gros-Horloge under the arch | 475 | 0.070 | 1.00 | ✗ | ✗ |
| F9F5F3C0 | Gros-Horloge from the street | 751 | 0.090 | 0.72 | ✗ | ✗ |
| 6552CA2F | façade rose window | 4131 | 0.109 | 1.00 | ✗ | ✗ |
| 5A9D30B2 | Gros-Horloge, street, JPEG | 433 | 0.110 | 1.00 | ✗ | ✗ |

Recall 6/13 at the brief's gate, 7/13 at 4 %; precision 13/13 across both.

### Residual-gate sensitivity (all 172 assets, every other gate as specified)

| gate | accepted assets | added versus the row above |
| --- | --- | --- |
| 0.03 (brief) | 6 | — |
| 0.04 | 7 | Gros-Horloge dial (true) |
| 0.05 | 8 | plane window (a rounded rectangle; borderline) |
| 0.06 | 14 | six river/street panoramas — **false** |
| 0.08 | 37 | mostly false |

The edge-map passes contributed one acceptance (the oculus) and no false
positives; the region-contour passes found the rest. Per pass, accepted
ellipses came from dark@2.0 ×2, light@2.0, light@1.0, dark@3.0, edge@0.06 — the
contrast sweep earns its keep.

## Groups (headline run, 3 % gate, 1920×1080, target 40 % of height)

| # | group | n | scale min / median / max | > 2× | coverage median / min | edge-excluded centred / aligned |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | ellipse · all | 6 | 0.31 / 0.65 / 0.83 | 0 | 94 % / 54 % | 3 / 3 |
| 2 | ellipse · head-on | 5 | 0.31 / 0.49 / 0.83 | 0 | 88 % / 54 % | 3 / 3 |
| 3 | quad · all (cap 30 of 58) | 30 | 0.28 / 0.68 / 0.89 | 0 | 74 % / 41 % | 23 / 28 |
| 4 | quad · wide | 26 | 0.17 / 0.57 / 0.85 | 0 | 64 % / 29 % | 22 / 26 |
| 5 | quad · wide · head-on | 10 | 0.17 / 0.60 / 0.84 | 0 | 63 % / 29 % | 8 / 10 |
| 6 | quad · wide · moderate | 14 | 0.31 / 0.59 / 0.85 | 0 | 64 % / 50 % | 12 / 14 |
| 7 | quad · square | 13 | 0.31 / 0.75 / 0.85 | 0 | 78 % / 48 % | 10 / 12 |
| 8 | quad · square · head-on | 6 | 0.35 / 0.58 / 0.83 | 0 | 70 % / 56 % | 6 / 6 |
| 9 | quad · square · moderate | 7 | 0.31 / 0.75 / 0.85 | 0 | 95 % / 48 % | 4 / 6 |
| 10 | quad · tall | 19 | 0.36 / 0.62 / 0.89 | 0 | 64 % / 44 % | 17 / 18 |
| 11 | quad · tall · head-on | 7 | 0.47 / 0.59 / 0.89 | 0 | 77 % / 62 % | 6 / 7 |
| 12 | quad · tall · moderate | 11 | 0.39 / 0.69 / 0.77 | 0 | 63 % / 50 % | 10 / 11 |

No near-misses of exactly 3. No ellipse subgroup other than head-on reached 3.
Full member tables (capture time, diameter, scale, obliquity, coverage) are in
`report-generated.md`; the machine-readable groups in `groups.json`.

**Resolution budget:** no asset in any group needs upscaling; the largest scale
factor is 0.89×. The 400 px / short-edge÷6 gate on 12 MP sources guarantees it.

**Edge policy:** with `exclude` (the brief's default) the headline pass rendered
50 of 344 item-renders; 59 distinct assets were excluded with shortfalls from 1 %
to 100 % of the frame. With `letterbox`, 344 of 344. In the portrait 1080×1920
variant (target 768 px major axis), the ellipse group kept 4 of 6 under `exclude`
(the two big shapes — rosette 1386 px, sign 1245 px — still shrink below full
coverage by 4–8 %).

## Proof clips (on this Mac, `tools/shapeseq/spike-out*/clips/`)

| clip set | what to watch it for |
| --- | --- |
| `spike-out/clips/group-01-{centred,aligned}.mov` | the brief's defaults: exclude + rotate-to-horizontal — 3 of 6 items, spinning world |
| `spike-out/clips/group-01-{centred,aligned}-letterbox-norot.mov` | **the judgeable ellipse clip** (6 items) |
| `spike-out-gate04/clips/group-01-*-letterbox-norot.mov` | the same with the Gros-Horloge (7 items) |
| `spike-out/clips/group-0[3-9,10-12]-*-letterbox-norot.mov` | the quad groups |
| `spike-out-portrait/clips/group-01-*-portrait-norot.mov` | portrait frame, exclude policy |
| `*-centred-sizeorder*.mov` | size-ordered variant of the "all" groups |

Frame-per-item review sheets (downscaled) are in `review/`:
`ellipse-group-gate04-centred-then-aligned.jpg` is the one to look at; the
`quad-*` sheets show a square, a tall and a wide head-on group;
`ellipse-group-rotation-major-rule.jpg` shows what the brief's rotation rule does.

### Review by eye

- **Ellipse group, no rotation, letterboxed:** reads as a held circle. Lens →
  clock → roundel → clock → oculus → sign → sign, one size, one place; the world
  cuts behind it. Size-ordered (ascending scale factor) plays as the letterbox
  bars receding — the source grows from a narrow strip to the full frame — which
  is a deliberate progression; chronological is arbitrary because these are one
  day's photographs.
- **Centred versus aligned:** indistinguishable on the head-on items (as the
  brief predicted for the control); the oculus at 0.84 is visibly rounder when
  aligned and its ornament stretches slightly — acceptable. No item was oblique
  enough to show the un-skew's cost or benefit on the surroundings.
- **Brief's rotation rule:** unusable for ellipses. Rotation should be
  conditional on the axis being determined (obliquity below ~0.9) or replaced
  by a scene-level cue (horizon), which is a different feature.
- **Quads:** the aligned variant levels every window and door into a true
  rectangle at one size, which is technically right, but the eye does not read
  "the same shape" across a window, a doorway, a colour-checker card and a sign
  board — rectangles are too common and too rarely the subject. Two members of
  the tall and wide head-on groups are false positives (a dark night region, a
  blank patch of sky) that `VNDetectRectanglesRequest` reports at confidence
  ≥ 0.6; a texture/contrast gate on the quad interior would remove them.

## Findings about the method

- **Vision's contour tracer is the cost.** `VNDetectContoursRequest` serialises
  every request in a process through one capacity-limited queue, so four
  workers collapse to one core, and its `maximumImageDimension` is superlinear:
  512 (Apple's default) costs 1–2 s per real photograph for the six passes;
  1024 costs 23–61 s. The tool hands Vision a 1024 image for rectangles and
  geometry but keeps the tracer at 512 (`--contour-dimension`). Quantisation at
  512 is ~8 native px on a 4032 image, well inside a 3 % gate on a 400 px shape.
- **The residual gate, not the detector, sets recall on textured circles.** The
  Gros-Horloge fit is correct (obliquity 0.99, coverage 0.97, centre right) and
  fails by 0.010. Edge-map contours help a little (one acceptance); a real gain
  would need an edge-point method — RANSAC/Hough on gradient points rather than
  region contours — which is still Apple-only (Accelerate) but is a different
  detector.
- **The affine un-skew is the honest first cut.** Mapping the fitted ellipse to a
  circle is a stretch along the minor axis; a metric rectification of the
  surroundings would need the focal length, which the preferred representative
  images (blends) do not carry.
- **Quads use a level-the-top-edge rotation**, not the brief's major-axis rule
  (which would lay every doorway on its side), and the aligned homography goes
  onto a rectangle of the group's median width/height — mixing wide and tall
  quads in the capped "all" group visibly distorts the minority.
- **The catalogue is a moving target while the Mac app is open**: the manifest
  grew from 109 to 186 captures during this session. The inventory stamps its
  scan time; `--stage detect` must be re-run to pick up new material.

## What the brief asked for and did not get

- Groups of "meaningful length" for ellipses: 6–7 is the ceiling of this
  catalogue. Rendering more would need shooting more.
- An un-skewed-versus-centred verdict: not decidable without oblique circles.
- The brief's rotation rule and exclude policy as-is: both rendered the
  ellipse clip unwatchable (3 of 6 items, spinning); the numbers above quantify
  it, the letterbox/no-rotation pass is what to judge.

## Reproduce

```bash
cd LetsLapse/tools/shapeseq && swift build -c release
B=.build/release/shapeseq; C=/Volumes/letslapse
$B selftest --out ./selftest
$B run --catalogue $C --out ./spike-out                                   # detect + group + render (brief defaults)
$B run --catalogue $C --out ./spike-out --stage render --edge-policy letterbox --rotation none --dump-frames --clip-tag letterbox-norot
mkdir -p spike-out-gate04 && cp -R spike-out/detections spike-out/cache spike-out-gate04/
$B run --catalogue $C --out ./spike-out-gate04 --stage sheets --residual-gate 0.04
$B run --catalogue $C --out ./spike-out-gate04 --stage group  --residual-gate 0.04
$B run --catalogue $C --out ./spike-out-gate04 --stage render --residual-gate 0.04 --groups 1 2 --edge-policy letterbox --rotation none --clip-tag letterbox-norot
```

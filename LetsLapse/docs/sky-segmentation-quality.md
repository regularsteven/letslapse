# Sky segmentation quality — measurement and findings

2026-08-31 · test subject: **Day to night 5k dng i16**
(`E33ED216-900E-4C47-9426-84BC7961D15F`, 5034 DNG, 4032×3024, Charles Bridge
day→night). Steven reported that the sky mask was visibly off at the
skyline — good enough in bulk, unprofessional under large type — and had
fallen back to a hand-drawn custom mask. This is what the pipeline actually
does, measured rather than guessed, and what the levers are worth.

**Reference:** the hand-drawn mask Steven made for this project
(`masks/6D2B2A8A….png`, 4032×3024, soft edges). It is a hand drawing, not
truth, so treat the absolute numbers as "distance from what the
photographer wanted" — which is the number that matters here anyway. Every
comparison below uses the same reference, so the *relative* results hold
regardless.

## What the model actually emits

`DETRResnet50SemanticSegmentationF16.mlmodelc`, read out of the compiled
`model.mil`:

- input `tensor<fp32, [1, 3, 448, 448]>` — the frame is stretch-resized to a
  square, so at 4032×3024 one grid cell is 9.0 px across and 6.8 px down
- output `tensor<int32, [448, 448]> semanticPredictions` — an **argmax label
  map**. There are no logits and no probabilities anywhere in the graph.

Confirmed against the cache: every per-frame grid in `SceneMasks/` holds
exactly **two** distinct values. A sequence vote over N frames holds N+1.

## The findings

**1. Threshold was a no-op in per-frame mode.** On a two-valued grid,
`CIColorThreshold` at 0.23 and at 0.50 produce byte-identical output — 
measured, IoU 0.9701 both ways. The dial had nothing to cut. It is now gated
on `SceneMask.carriesConfidence`, and says why when it is off.

**2. Edge bias was costing accuracy and pushing type over the roofline.**
The spike's 1.5 default erodes the restoring region, which for Sky placement
is the buildings. Measured cost: **−0.29 IoU points**, and every letter sits
that much further over the skyline. Default is now 0, and the dial is
bipolar — negative grows the occluder, which is what a spiky skyline wants.

**3. The fixed r=2 open/close is harmless.** Suspected of eating spires;
measured at 0.9731 → 0.9730. Left alone.

**4. Voting beats any single frame, so the locked-off case is now the
assumption.** Across 9 cached masks of this scene: mean single frame 0.9588,
best single frame 0.9731, **vote 0.9754**. A timelapse is shot on a tripod;
the skyline is identical in every frame. The symmetric "Sequence / This
frame" control is now "Camera locked off", checked by default, with
per-frame re-detection as the opt-out for a camera that moved.

**5. Raising the vote from 9 to 25 samples bought resolution in the VALUES,
not accuracy.** 25-sample vote scored 0.9753 against the 9-sample 0.9754 —
identical. What it bought is 26 threshold levels instead of 10, which is
what makes the dial usable at all, plus more robustness against the frames
where the model loses the plot at dusk (worst single frame here: 0.9098).
Costs ~35 s once per project on a DNG shoot, cached forever after.

**6. The optimum threshold is near the BOTTOM of the range, not the middle.**
Swept on the vote: best at 0.05–0.15, monotonically worse above. The model
systematically under-calls sky next to buildings, so "if any frame said sky,
it is sky" wins. The 0.5 default is probably wrong, but one scene is not
enough evidence to move it.

## What the error actually is

Whole-frame IoU is 0.9731 — which sounds fine, and is why this took
measuring to see. The structure of the error is the point:

- **100% of disagreeing pixels sit within 50 px of the skyline** (median 7,
  p90 22). There are no gross misses: no sky found inside buildings, no
  missed regions.
- The error is not noise. The model draws a **rounded-off silhouette** — it
  bridges the notches between spires and clips the peaks. In an overlay diff
  it reads as red filling the gaps and green capping the towers.

**Resolution is not the bottleneck.** Squash the hand mask to 448 and bring
it back — what a *perfect* model on this grid would score — and it is
**0.9977**. So of the 2.69 points of error, 0.23 is the grid and **2.46 is
the model being wrong**. Tiled or higher-resolution inference has almost
nothing to win.

## The correction: measure the boundary, not the frame

Whole-frame IoU nearly cannot see the thing being complained about — the
boundary band (within 40 px of the skyline) is 6.4% of the frame. Google's
*Sky Optimization* paper makes exactly this point: their Boundary Loss
metric "correlates with perceptual quality better than the other metrics".

Re-measured on the band alone, with the photograph as a guide image:

| | whole-frame IoU | boundary error |
| --- | --- | --- |
| today: upscale then threshold | 0.9731 | **18.20%** |
| + guided filter r=64, ε=0.001 | 0.9770 | 13.59% |
| + guided filter r=128, ε=0.001 | 0.9779 | **12.85%** |

**A 29% relative reduction in boundary error, with no new model.** The first
pass at this was dismissed because whole-frame IoU moved by 0.3 points; that
was the wrong ruler.

This is what Google ships: segmentation at **256×256** — coarser than ours —
upsampled with a weighted guided filter and kept as *continuous alpha*
rather than thresholded. SkyAR's sky-matting network is the learned version
of the same shape: a coarse matte plus a refinement module that takes the
coarse matte and the high-resolution image together.

Note our pipeline currently thresholds to binary *before* upsampling and
feathers afterwards, which is backwards: it throws the soft boundary away
and then fakes one.

## Second scene, and the fix (2026-09-01)

Steven ran the tuned pipeline on **Overloaded Charles dng i12**
(`3355871A-…`, 4368 DNG, same 4032×3024) with no hand-drawn mask, and it
still showed a halo. Two findings.

**The threshold was doing most of the damage.** With no reference mask to
score against, the metric is *how far the mask boundary sits from a real
edge in the photograph* — a strong-gradient distance transform, no ground
truth needed. Sweeping threshold on the 26-level vote:

| threshold | sky area | mean distance from a real image edge |
| --- | --- | --- |
| 0.05 | 42.5% | 9.9 px |
| 0.53 (Steven's) | 41.9% | 16.3 px |
| 0.80 | 41.4% | 22.2 px |

The area barely moves; the boundary moves a lot. A high threshold pulls the
sky back off the skyline and *is* the halo.

**Guided-filter refinement, now implemented.** On this scene it takes the
boundary from **12.6 px to 4.9 px** from a real edge — a 61% reduction, and
better than threshold-tuning alone, so it is genuinely snapping to edges
rather than just moving the boundary.

Implementation notes, all learned the hard way:

- **`CIGuidedFilter` is a trap.** It appears in `CIFilter.filterNames`, it
  accepts every parameter without complaint, and it is a **byte-for-byte
  no-op** — output identical to input at every radius and epsilon. There is
  no typed `CIFilter.guidedFilter()` builtin either. It is registered but
  not functional.
- **`CIEdgePreserveUpsampleFilter` does work** and is the designed tool
  (small image + guide → upsampled). It gets 12.6 → 7.6 px at
  `lumaSigma` 0.05–0.02, `spatialSigma` irrelevant. Kept as the reference
  point; the hand-rolled filter beat it.
- The shipped version is the real guided filter (He et al.): five
  `CIBoxBlur`s and two `CIColorKernel`s. The legacy `CIColorKernel(source:)`
  still compiles at runtime, which avoids adding `-fcikernel` build flags
  for a single kernel; both kernels are optional and refinement is skipped
  if they ever stop compiling, degrading to exactly today's behaviour.
- **The context must use a float working format.** The guided filter carries
  signed, unbounded coefficients (`a`, `b`) between stages; in an 8-bit
  intermediate `a` clips and `b` loses its sign, and the whole thing
  silently becomes a no-op. `CIContext(.workingFormat: .RGBAh)`.
- Radius is a **fraction of the long edge** (0.032), not an absolute pixel
  count, so the 1100 px scrub and the full-resolution export refine
  identically — the same rule overlay size follows.
- Cost: **+19 ms/frame** at 4032×3024 (12 → 31 ms), ~5 ms on a 2000 px
  preview. Small next to the decode-bound blend.

### A caveat on scene 1's numbers

Scene 1's guide frame and its hand mask are **~16 px misregistered** (they
are different frames of the same locked-off shoot; measured by cross-
correlation). Any edge-snapping method is penalised there for snapping to
the frame it was given rather than the one the mask was drawn on. That is
why the refinement scores 18.20% → 16.79% on scene 1 but 12.6 → 4.9 px on
scene 2, where mask and guide are the same frame. **Scene 2's numbers are
the trustworthy ones**; scene 1's are a floor.

## What separates sky from land, across a day→night run

Measured for the manual-correction job below — which signal a "click the
clear sky" tool could actually key on. Overlap is how much the two
distributions sit on top of each other; 0% means trivially separable.

| frame | mean luma | luminance | saturation | local texture |
| --- | --- | --- | --- | --- |
| 00200 (day) | 151 | **0.4%** | 20.8% | 2.2% |
| 02500 (dusk) | 163 | 6.0% | 25.9% | 3.9% |
| 04800 (night) | 75 | **37.1%** | 25.3% | **55.2%** |

In daylight luminance is very nearly a perfect discriminator. **At night it
collapses**, and so does texture: the sky goes dark and flat while the city
lights up, so the buildings become the bright, textured thing and the
relationship inverts. Saturation is mediocre throughout but is the only
signal that does not collapse.

The consequence is a product one rather than an algorithmic one: because the
camera is locked off, a correction only has to work on ONE frame and then
serves the whole shoot — so the tool should be used on a bright frame, and
the app is in a position to pick that frame (it already samples 25 for the
vote, so the separability numbers above are nearly free to compute).

## Ranked levers, with what each is worth

1. ~~**Guided-filter refinement against the frame**~~ — **DONE 2026-09-01.**
   Boundary 12.6 → 4.9 px on scene 2.
2. **Keep continuous alpha** end to end instead of threshold-then-feather.
   Now the biggest remaining structural item: the chain still thresholds to
   binary before the refinement gets to see it.
3. **A better model** — 2.46 IoU points is the model, so this is still the
   biggest single term, but it is a bigger job than 1 and 2 combined.
   Candidates: ADE20K scene-parsing models with a real `sky` class (DNL,
   ISANet, FastFCN, SegFormer at 512²) or a sky-specific matting network.
4. Sample count / threshold defaults — worth tenths of a point.
5. **Tiled or higher-resolution inference — not worth it.** The ceiling test
   says ≤0.23 points are available.

## Reproducing

The cached grids are the evidence; nothing here needs inference to re-check.
Grids live at `<StorageRoot>/SceneMasks/*.png` (448×448 gray PNG), the hand
mask at `<project>/masks/<uuid>.png`. Compare with numpy + opencv from
`tools/.venv`. A source frame decodes with `sips -s format jpeg` — and
because the shoot is locked off, any frame serves as the guide image.

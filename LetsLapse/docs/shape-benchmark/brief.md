# LetsLapse — Shape Detection Benchmark Rig

**Type:** Offline benchmark rig, run on macOS against the "Shape testing" corpus in the Mac library
**Status:** Investigation brief, pre-implementation → tool built 2026-09-11
**Target:** Developer agent (macOS, Apple Silicon)

(Brief as received 2026-09-11; the tool is `LetsLapse/tools/shapebench` (Python, in
`tools/.venv`), the findings are in `report.md` alongside this file. Decisions taken with
Steven the same day: the v2 multi-run schema stays rig-side until the §8 decision — the
library's `shapes.json` is only read, never written; adoption inside Kit is a TODO entry.
Ellipse ground truth is click-rim-points-then-fit rather than a drag, so rotation is
captured and labels pass through the same normaliser as every detector.)

---

**Date:** 2026-09-11
**Scope:** LetsLapse — photo-mode captures only
**Audience:** Developer agent (macOS, Apple Silicon)
**Status:** Investigation brief, pre-implementation

---

## 1. Purpose

LetsLapse already detects shapes via Apple Vision (Create → Create Shape-mation → Find shapes). Results are inconsistent and there is currently no way to say *how* inconsistent, because there is nothing to measure against.

This brief specifies an offline benchmarking rig that:

1. Produces a trustworthy reference set of shape detections from a tagged corpus of photos.
2. Measures the existing Vision implementation against that reference.
3. Answers one decision at the end: **is a semantic ranking layer (AI model) needed for photo mode, or do geometric rules alone suffice?**

Out of scope: interval shoots, video shoots, live camera-preview detection. Lessons from this work will be carried into those later.

---

## 2. Core architectural position

**Language models do not measure geometry.** A VLM can reliably say *there is a circular window in the upper left*. It cannot return corner coordinates or an aspect ratio accurate enough to align a crop against. Since the entire downstream use is positioning a crop so a circle in one photo lands where a circle in the next photo sits, geometric precision is the product.

The pipeline therefore separates two jobs that must never be conflated:

| Job | Responsibility | Precision required | Input |
|---|---|---|---|
| **Proposal** | "There is a shape-like region here, and it is meaningful" | Low | Downscaled JPEG acceptable |
| **Measurement** | Exact centre, extent, rotation, aspect ratio | High | Full resolution, local only |

Measurement is always classical (contour extraction and primitive fitting), always runs at full resolution, and never leaves the device. Proposal is currently handled implicitly by geometric filtering; whether it needs an AI model is the question this rig answers, not an assumption it starts from.

---

## 3. Shape specification

These values are specified, not spitballed. All are configurable, with the values below as shipped defaults.

### 3.1 Primitive set

Two primitives only:

- **Rectangle** — includes squares as a sub-classification.
- **Ellipse** — includes circles as a sub-classification.

No trapezoids, no polygons, no arbitrary contours.

### 3.2 The image-space rule

**All geometry is measured in image space, not world space.** A rectangle is a rectangle if it presents as one in the photograph, regardless of the real-world object's orientation.

This resolves what looks like an inconsistency (why reject an oblique rectangle but accept an oblique circle?). The answer is that it is not an inconsistency, it is a property of the primitive set:

- A real-world rectangle viewed obliquely projects as a **trapezoid**, which is not a supported primitive, so it is correctly rejected.
- A real-world circle viewed obliquely projects as an **ellipse**, which *is* a supported primitive, so it is correctly accepted.

The rule is the same in both cases: measure what is in the image. This is the right call for LetsLapse because alignment operates on 2D crops — aligning a face-on square against a keystoned one would look wrong on screen.

### 3.3 Size bands

Size is measured as **extent ratio**: the shape's axis-aligned bounding box compared against the frame, taking the larger of the two ratios.

```
extentRatio = max(bboxWidth / frameWidth, bboxHeight / frameHeight)
```

Linear extent, deliberately, not area. Area does not work here: the largest circle that fits a 4:3 frame covers only about 59% of it by area, so an area-based "large = 70%" band would never match a single circle.

| Band | Range |
|---|---|
| *(discard)* | `extentRatio < 0.10` |
| Small | `0.10 ≤ extentRatio < 0.35` |
| Medium | `0.35 ≤ extentRatio < 0.65` |
| Large | `extentRatio ≥ 0.65` |

The 0.10 hard floor is the primary salience filter. It is what removes brick courses, paving slabs, window mullions and sign edges — the high-recall noise that makes a detector technically accurate and practically useless. Expect to tune it after the first run against the corpus.

Existing sensitivity/size settings in Find Shapes map onto these bands. Sensitivity should adjust the acceptance thresholds in §3.4 and §3.5, not the size floor.

### 3.4 Rectangle acceptance criteria

A candidate contour qualifies as a rectangle when all of the following hold:

| Test | Threshold | Rationale |
|---|---|---|
| Vertex count after polygon approximation | exactly 4 | |
| Convexity | must be convex | |
| Interior angles | each within **90° ± 8°** | 8°, not 5°. Lens distortion, JPEG edge noise and contour approximation error all eat into the budget before real perspective does; 5° rejects genuine face-on rectangles near frame edges. The measured deviation is recorded, so a tighter filter can be applied later without re-detecting. |
| Opposite side length agreement | within **10%** of each other | Catches trapezoids that scrape through the angle test |
| Fill ratio | `contourArea / fittedRectArea ≥ 0.85` | Rejects concave or hollow forms that approximate to a quad |

**Square sub-classification:** aspect ratio within `1.00 ± 0.05`.

Record `maxAngularDeviationDeg` on every accepted rectangle — the largest deviation from 90° across its four corners. This is the obliqueness signal, and it is usable because for rectangles the undistorted form is known.

Note that no equivalent obliqueness figure is recorded for ellipses. It is not recoverable: a given ellipse could be an oblique circle or a face-on oval, and nothing in the image distinguishes them without depth or object recognition. Do not fabricate one.

### 3.5 Ellipse acceptance criteria

| Test | Threshold |
|---|---|
| Fitted ellipse agreement | `IoU(contourMask, fittedEllipseMask) ≥ 0.90` |
| Minimum eccentricity | `minorAxis / majorAxis ≥ 0.40` — below this it is a sliver, not a usable alignment target |

**Circle sub-classification:** `minorAxis / majorAxis ≥ 0.95`.

### 3.6 Aspect ratio and orientation

Recorded separately on every shape, always with ratio ≥ 1.0:

- **Rectangle:** `longSide / shortSide` from the minimum-area rotated rect. Orientation is the rotated rect's angle.
- **Ellipse:** `majorAxis / minorAxis`. Orientation is the major axis angle.

Orientation in degrees, normalised to `[0, 180)`.

---

## 4. Output format

The benchmark depends entirely on every detector emitting the same structure. This replaces the current `shapes.json`.

### 4.1 Cache versioning — do not flush

The existing cache skips already-analysed projects, and the instinct is to flush it and start clean. **Do not.** Flushing destroys exactly the comparisons this exercise exists to produce.

Instead, key every result set by `detectorId` + `detectorVersion` + `paramsHash`. Multiple runs then coexist in one file, "skip if already analysed" becomes "skip if this exact detector/params combination has already run", and the diff between any two runs is a lookup rather than a re-shoot. This makes the benchmark a first-class part of Find Shapes rather than a throwaway script, and gives the mode-switching UI most of what it needs for free.

### 4.2 Schema

```json
{
  "schemaVersion": 2,
  "projectId": "UUID",
  "runs": [
    {
      "detectorId": "opencv-reference | apple-vision | manual-groundtruth",
      "detectorVersion": "1.0.0",
      "paramsHash": "sha256-truncated",
      "params": { "sizeFloor": 0.10, "angleToleranceDeg": 8.0 },
      "runAt": "2026-09-11T10:00:00Z",
      "durationMs": 1240,
      "assets": [
        {
          "assetId": "UUID",
          "frameWidth": 4032,
          "frameHeight": 3024,
          "shapes": [
            {
              "shapeId": "stable-uuid",
              "primitive": "rectangle",
              "subclass": "square",
              "centre": { "x": 0.412, "y": 0.338 },
              "extentRatio": 0.47,
              "sizeBand": "medium",
              "aspectRatio": 1.02,
              "orientationDeg": 3.4,
              "vertices": [ { "x": 0.31, "y": 0.24 } ],
              "axes": null,
              "confidence": 0.91,
              "maxAngularDeviationDeg": 2.7,
              "fillRatio": 0.94
            }
          ]
        }
      ]
    }
  ]
}
```

All coordinates normalised `0.0–1.0` against frame dimensions, so results survive any downscaling and stay comparable across devices and capture resolutions. `vertices` is populated for rectangles; `axes` (`{ major, minor }`, normalised) for ellipses.

`confidence` is the fit quality that produced the shape — fill ratio for rectangles, mask IoU for ellipses. It is a geometric figure, not a semantic one, and should not be read as "how likely is this to be an interesting shape".

---

## 5. Rig stages

### Stage 1 — Candidate generation

Each detector runs independently over the same corpus and writes its own run block. No detector is privileged at this stage. **Apple Vision output is recorded as one candidate source among several, never as truth.**

Initial detectors:

- `opencv-reference` — Python/OpenCV on the Mac. Multi-scale Canny with adaptive thresholding, contour extraction, then §3.4/§3.5 fitting. This is the workhorse.
- `apple-vision` — existing in-app implementation, output normalised into the schema above.
- `manual-groundtruth` — human labels (§6).

### Stage 2 — Normalisation and fitting

Every candidate region, whatever produced it, goes through one shared fitting pass: fit both a rotated rectangle and an ellipse, score each against the region, take the better fit, apply the §3 acceptance rules, emit or discard.

This matters. It means detectors are compared on their ability to *find* regions, not on their individual and incomparable ideas of how to describe them.

### Stage 3 — Consensus and metrics

Two shapes from different runs are considered the same shape when **all** of:

- same `primitive`
- centre offset ≤ 2% of frame diagonal
- IoU ≥ 0.70
- aspect ratio within 10%

Report per detector, against ground truth:

- Precision and recall
- Aspect ratio error — median and 95th percentile
- Centre offset distribution — as % of frame diagonal
- Candidates per image — median and distribution
- Runtime per image

---

## 6. Ground truth

The rig cannot be trusted until it has been checked against a person once.

Hand-label **25 photos** sampled across the "Shape testing" tagged corpus, covering a spread of lighting, subject distance and clutter. For each, record every shape a human would consider a plausible alignment target, marked up with corners or centre/axes, written directly into the `manual-groundtruth` run block.

Twenty-five is enough to validate, small enough to do in one sitting. This is a one-time cost. Once the OpenCV reference agrees with the labels, it becomes the reference for the rest of the corpus and no further labelling is needed.

A simple labelling tool is required — click four corners for a rectangle, drag for an ellipse, assign primitive. It does not need to be pretty, and it should not live in the shipping app.

---

## 7. Phases

| Phase | Deliverable | Exit criteria |
|---|---|---|
| **0** | Harness: export "Shape testing" tagged photos to a flat working directory with `assetId` preserved | Corpus exported, count reported |
| **1** | `opencv-reference` detector implementing §3 in full | Runs over the whole corpus, emits schema-valid output |
| **2** | Labelling tool and 25-image ground truth set | Labels committed |
| **3** | Validation: OpenCV reference vs ground truth | Precision and recall reported; thresholds tuned once against results |
| **4** | `apple-vision` output normalised into the schema; full comparison run | Metrics table for Vision vs reference |
| **5** | Decision gate (§8) | Documented recommendation |

Phases 1–3 are the load-bearing work. If the OpenCV reference does not agree with a human on 25 images, nothing downstream is worth measuring, and tuning stops there until it does.

---

## 8. Decision gate: is an AI ranking layer needed?

The reason to want an AI model in this pipeline was salience — distinguishing the clock face a person would align on from the four hundred bricks around it. The §3.3 size floor and the §3.4 angle rules may have already solved that problem geometrically.

Measure, then decide, using median candidates per image from Phase 3:

| Median candidates/image | Conclusion |
|---|---|
| **≤ 6** | Geometry alone is sufficient for photo mode. No AI ranking layer. Ship it. |
| **7–15** | Borderline. Try tightening the size floor and re-measuring before adding a model. |
| **> 15** | Ranking is needed. Proceed to §9 with a defined job and a measurable baseline. |

Do not add a model before this number exists.

---

## 9. If ranking is needed (contingent, do not build yet)

Should the gate trigger, the AI layer's job is narrow and specific: **given N geometrically valid candidates, rank them by how likely a person is to choose them as an alignment target.** It proposes and ranks. It never measures.

Design constraints for that work:

- Candidates are rendered as a numbered overlay on a downscaled JPEG (long edge 768px, configurable) and the model returns an ordered list of candidate IDs. It is never asked for coordinates.
- Downscaling is safe here precisely because the model only returns IDs. Geometry has already been measured at full resolution in Stage 2.
- Provider abstraction behind one interface, with a provider picker and per-provider model selection: on-device MLX models from the Settings AI catalog, Ollama (macOS), and third-party APIs (OpenAI, Z.AI, Claude). macOS may offer heavier models than iOS.
- The ranker slots in as an additional run block. It is benchmarked exactly like any other detector, against the same ground truth, and it earns its place or it does not.

---

## 10. Open item

Live camera-preview detection is deliberately unresolved. The question of whether it is needed at all depends on how good post-capture detection proves to be, and that is what this rig is for. Revisit after Phase 5.

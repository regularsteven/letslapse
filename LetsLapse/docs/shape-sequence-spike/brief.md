# LetsLapse — Shape Sequence Spike

**Type:** Offline research tool, run against the existing LetsLapse catalogue on macOS
**Status:** Spike / validation. Not a shipping feature, not app code.
**Target:** Developer agent working in Swift on Apple Silicon macOS

(Brief as received 2026-09-10; the tool is `LetsLapse/tools/shapeseq`, the
findings are in `report.md` alongside this file.)

---

## 1. Purpose

Determine whether the existing LetsLapse catalogue contains enough
shape-alignable material to justify building a Shape Sequence feature into
the app, and prove that the alignment maths produces something worth
watching.

The concept: many photographs and interval shoots contain a dominant
geometric shape — a clock face, a manhole cover, a rounded window, a
doorway, a sign. If those shapes are detected, normalised to a common
position and scale, and played in sequence, the shape appears to hold
still while the world behind it changes. This tool finds those candidates
automatically and renders proof clips.

**This spike answers three questions:**

1. Does automatic shape detection find usable anchors in real catalogue
   material, or does it mostly find noise?
2. Are there enough co-shaped assets in one catalogue to form sequences of
   meaningful length?
3. Does the aligned result actually read as a held shape, or does it read
   as a jumble?

A negative answer to any of these is a valid and useful outcome. Report it
plainly rather than tuning until the numbers look good.

## 2. Hard constraints

- Read-only against the catalogue. All output goes to a tool-owned working
  directory specified on the command line.
- No modification of the app data model. Anchor data lives in the tool's own cache.
- Apple frameworks only (Vision, Core Image, AVFoundation, Accelerate, simd) plus
  `swift-argument-parser`. No OpenCV, no Python, no model downloads.
- On-device, no network calls.
- Tripod-locked sources assumed: one anchor per shoot, no per-frame tracking.
- Stills and blended interval outputs only; handheld video sources are skipped and logged.

## 3. Deliverables

`detections/contact-sheet-*.png`, `detections/anchors.json`, `groups/report.md`,
`groups/groups.json`, `clips/group-NN-aligned.mov`, `clips/group-NN-centred.mov`,
`run-log.txt`. Swift Package executable; `shapeseq run --catalogue … --out …`
with `--stage detect|group|render`.

## 4. Pipeline

4.1 Inventory (one representative image per shoot: blended output → rendered
JPEG/HEIC → DNG last, logged). 4.2 Detection at 1024 px: quads via
`VNDetectRectanglesRequest` (minimumAspectRatio 0.3, maximumObservations 12,
minimumConfidence 0.6, quadratureTolerance 30); ellipses via
`VNDetectContoursRequest` (dark/light × contrast 1/2/3) → polygon-approximation
reject → direct least-squares conic fit; gates: closed, mean radial residual
< 3 % of major axis, ≥ 70 % circumference coverage, minor/major ≥ 0.25,
native diameter ≥ max(400 px, shorter edge ÷ 6); nested/overlapping → best
residual wins; rejected candidates recorded with reasons. 4.3 `ShapeAnchor`
model in a standalone `ShapeDetectionService(CGImage)`. 4.4 Grouping by kind,
minimum 4 (3 = near-miss), one large group plus obliquity sub-groups
(≥ 0.85 head-on, 0.5–0.85 moderate, 0.25–0.5 oblique), quads also by aspect;
chronological plus size-ordered; cap 30 by confidence. 4.5 Render 1920×1080
H.264 30 fps, 1.0 s per item, hard cuts; major axis = 40 % of frame height at
frame centre; centred (translate/scale/rotate) and aligned (homography first)
variants; edge policy exclude (default) or letterbox; burned caption.

## 5. Resolution budget

Report the scale-factor distribution per group; flag anything over 2.0×
upscale; render anyway and say so.

## 6. Non-goals

Blending, duration ramps, UI, manual anchors, tracking, video sources,
semantic labels, writing anchors into project data, multi-project concerns.

## 7–8. Success criteria & reporting

Numbers: assets scanned, assets with ≥ 1 accepted anchor, rejection
breakdown, largest viable group per kind, scale distribution, edge
exclusions; proof clips judged by eye, un-skewed vs centred. Report opens
with a plain-language verdict written for someone deciding whether to spend
a month on this.

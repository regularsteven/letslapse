# shapeseq — the Shape Sequence spike

> **2026-09-10:** the spike became the Shape-mation feature the same day. The
> detector, the ellipse fit, the register model and the composer now live in
> the Kit (`Kit/Sources/LetsLapseKit/Shapes/`, tests in `ShapeDetectorTests`)
> and the screens in `App/Shapemation/` (Create ▸ *Create Shape-mation*). This
> tool stays as the offline instrument — contact sheets, groups, proof clips.

Offline research tool for the question in `docs/shape-sequence-spike/brief.md`:
does the existing catalogue hold enough *shape-alignable* material (clock
faces, manhole covers, round windows, doorways, signs) to justify a Shape
Sequence feature, and does aligning those shapes read as a held shape?

Read-only against the catalogue, Apple frameworks only (Vision, Core Image,
AVFoundation, simd) plus `swift-argument-parser`. Nothing is written into a
project directory; anchors live in the tool's own output.

## Build & run

```bash
cd LetsLapse/tools/shapeseq
swift build -c release
.build/release/shapeseq run --catalogue /Volumes/letslapse --out ./spike-out
```

`--catalogue` takes the storage root (`…/LetsLapse`, the folder holding
`Projects/`) or the `Projects/` folder itself. On this Mac the library is
the custom root `/Volumes/letslapse`.

Stages read the previous stage's JSON, so detection is not repeated on every
render tweak:

```bash
shapeseq run --catalogue … --out ./spike-out --stage detect   # inventory + anchors + contact sheets
shapeseq run --catalogue … --out ./spike-out --stage group    # groups.json + report.md
shapeseq run --catalogue … --out ./spike-out --stage render   # proof clips
shapeseq selftest --out ./selftest                            # synthetic ellipse + quad, checks the fit and the transform
```

Useful flags: `--limit N` / `--only <id-prefix>…` (iteration), `--target-fraction 0.4`,
`--frame-width/--frame-height`, `--seconds-per-item 1.0`, `--edge-policy exclude|letterbox`,
`--rotation major|none` (ellipse rotation rule), `--min-group 4`, `--max-group 30`,
`--concurrency 4`, `--size-order-all`.

## Output (`--out`)

| path | what |
| --- | --- |
| `detections/contact-sheet-NN.png` | 8×5 tiles per 40 shoots; green = accepted ellipse, cyan = accepted quad, red/orange = rejected. The primary review artefact. |
| `detections/anchors.json` | every candidate with geometry, confidence, and rejection reason; per-asset summary |
| `detections/inventory.json` | the asset list: representative image, source kind, native size, timestamp |
| `groups/groups.json`, `groups/report.md` | candidate sequences and the human-readable report |
| `clips/group-NN-centred.mov` / `-aligned.mov` | proof clips (1080p H.264, 1 s per item, hard cuts, captioned) |
| `clips/group-NN-centred-sizeorder.mov` | the size-ordered variant (per-kind "all" groups) |
| `cache/reps/<id>.jpg` | the ≤1024 px representative used for detection |
| `run-log.txt` | every skip and failure |

## Pipeline

1. **Inventory** — `Projects/library.json` (captures + blends) plus a folder
   walk for unlisted directories. Video-mode shoots are skipped. Representative
   image: rendered blend image → mid frame of a rendered blend clip → middle
   rendered source frame → RAW decode last (logged as `raw-decode`).
2. **Detect** at ≤1024 px. Quads via `VNDetectRectanglesRequest`; ellipses via
   `VNDetectContoursRequest` (dark-on-light × light-on-dark × contrast 1/2/3),
   polygon-approximation reject, then a Halir–Flusser direct least-squares conic
   fit with the brief's gates (residual ≤3 %, coverage ≥70 %, minor/major ≥0.25,
   native diameter ≥ max(400 px, short edge ÷ 6)).
3. **Group** by kind, then obliquity bucket (and aspect bucket for quads).
   Minimum 4, near-misses of 3 reported, cap 30 by confidence. Chronological
   order plus a size-ordered variant.
4. **Render** — `AVAssetWriter`, Metal `CIContext`. *Centred* = translate +
   uniform scale + rotation; *aligned* = the ellipse→circle affine stretch or the
   quad→rectangle homography first. Default edge policy excludes items whose
   crop leaves the source; `--edge-policy letterbox` pads with black.

`ShapeDetectionService` is the piece that would move into the app if this
validates; it takes a `CGImage` and a `CVPixelBuffer` overload is the obvious
next step for the armed-recording preview.

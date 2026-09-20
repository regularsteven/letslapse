# Shape-mation — the output frame (brief §4 + §5)

Decided 2026-09-19 with Steven after the mixed-scene run
(`mixed-scenes-report.md`): stack and crop-to-fill are not the output model
for a real set — the smallest face sets the working scale and a 14× size
range turns the tram into a 52 px speck on a 1920 frame. The brief's §4 is
the model: **the user chooses the output rectangle and where the face sits
in it; every photo is scaled and placed to put its face there; what does not
fit is flagged (§5).** Built code-first (Steven's call); the SVG mirrors are
owed after sign-off.

## 1. The framing

```swift
public struct ShapemationFraming: Codable, Equatable, Sendable {
    public var outputSize: CGSize           // even pixels, e.g. 1920×1080, 1080×1080
    public struct Key: Codable, Equatable, Sendable {
        public var at: Double               // 0 = the first photo, 1 = the last (by index)
        public var face: CGPoint            // where the face's centre sits, unit coords of the output rect, y-down
        public var size: Double             // the face's long side as a fraction of the output HEIGHT
    }
    public var keys: [Key]                  // ≥ 2, sorted by `at`; first at 0, last at 1
    public enum Ease: String, Codable { case linear, inOut }
    public var ease: Ease                   // between neighbouring keys
    public var upscaleCap: Double           // flag a photo scaled up beyond this (default 2)
    public func framing(at t: Double) -> (face: CGPoint, size: Double)
    public static func still(outputSize:face:size:) -> ShapemationFraming        // one framing throughout
    public static func approach(outputSize:from:to:) -> ShapemationFraming       // size (and place) at the first and last photo
}
```

"Every frame gets its own position, scale and crop" is per PHOTO in this
pass (`t = index / (count − 1)`; a hold is static). Motion inside a hold
(the Ken Burns idiom) is a later pass and slots into the same evaluator.

## 2. The mode and the plan

`ShapemationMode` gains `.frame` ("Output frame") beside `.stack` and
`.crop`. `ShapemationPlan.make(items:mode:match:framing:)` — `framing` is
required for `.frame`, ignored otherwise.

For `.frame`: `canvas` = the output rect at the origin. For item *i* in the
given (sorted) order: `(face, size) = framing(at: t)`, `targetPx = size ×
outputHeight`, `scale = targetPx / majorPx`, and the transform is
`translate(face × outputSize) · scale · <the family placement exactly as
today: un-tilt / level / homography onto the class rectangle> · centred`.
Each `Placement` gains:

```swift
public var target: CGPoint          // where this photo's face centre was put, output px
public var targetSizePx: Double     // the face's long side there
public var feasibility: Feasibility
public struct Feasibility: Equatable, Sendable {
    public var shortfall: (left: Double, top: Double, right: Double, bottom: Double)  // output px the photo FAILS to cover on each side, 0 when covered
    public var upscale: Double                                                        // the scale factor applied (> 1 = upscaled)
    public enum Verdict: String, Sendable { case fits, short, upscaled, shortAndUpscaled }
    public var verdict: Verdict     // short when any shortfall > 0.5 px; upscaled when upscale > framing.upscaleCap
}
```

The per-side shortfall is the gap between the frame's edge and the
axis-aligned bounds of the photo's transformed corners; the verdict is
decided exactly — the frame is covered iff each of its four corners lies
inside the convex quad of the photo's corners, which holds for affine and
projective placements alike (straight edges stay straight). The box around
a rotated or projected quad strictly contains it, so a levelled oval's
tilt, a circle's un-tilt shear or a rectangle's homography can reach every
frame edge and still leave a black corner: such a corner reports its
distance to the nearest photo edge on both of its sides (amended 2026-09-20;
the first cut judged on the bounds and read `fits` there). Nothing is
excluded by the plan — **flag and keep** (Steven's default): the caller
decides. `plan.shapeSizePx` is the first placement's
`targetSizePx` for the fields that still read it; `anchor` is the first
target.

## 3. The evaluator and the renderer

`ShapemationFrameEvaluator.image(item:decoded:placement:outputSize:canvas:)
→ CIImage` — one photo through its placement, cropped to the output rect,
over black. `canvas` is the plan's (the framing's output rect under
`.frame`) and is what `outputSize` scales from, so the builder's reduced
preview and the full-size render share one transform — it cannot be
derived from `outputSize` alone, hence on the signature. Extracted from the renderer's loop so the app's scrubber and
the render share one path. In `.frame` mode `ShapemationRenderer` writes one
photo per hold over BLACK — no accumulation — through the evaluator;
`.stack`/`.crop` keep the table. Poster = the last frame.

## 4. The scorer

`ShapemationScore.measure` compares the transformed truth to the item's
own `target` / `targetSizePx` when they are set (frame mode), else to
`anchor` / `shapeSizePx` as today; the SCORE line gains `flagged: short N ·
upscaled M`.

## 5. The CLI

`plan | score | render … --mode frame --frame 1920x1080 --face 0.5,0.55@0.25
[--face-end 0.5,0.55@0.5] [--ease linear|inout] [--upscale-cap 2]`. The plan
JSON gains `framing` and per-item `target`, `targetSizePx`, `feasibility`;
the table prints one verdict per row and a tally line. `render --mode frame`
writes at the framing's output size (no --size needed).

## 6. The builder (code first)

- Mode step: a third card, "Output frame — pick the frame; the face is put
  at a chosen size and place in every photo; what won't fill it is flagged".
- Output step for `.frame`: aspect (1:1 · 4:5 · 3:2 · 16:9 · 2:3 · 9:16)
  and size (1080 · 1920 · 2160 long edge); **face size** start and end
  (10–80 % of the height, steps of 5); **face place** start and end (a nine-
  point picker — the §6 cells — with (0.5, 0.55) as "centre"); a **scrub**
  slider over the photos showing photo *i* through the evaluator at ≤ 2048
  px decode with its verdict badge, and one line: "N photos won't fill the
  frame · M would be upscaled past 2×". Create renders as today; the record
  stores the framing.
- `ShapemationStore.Record` gains `framing: ShapemationFraming?` (tolerant
  decode); the subtitle says "frame" for the mode.
- Hooks: `LL_SHAPEMATION=frame` lands on the Output step with `.frame`
  chosen over the same projects `build` seeds.
- Mirrors owed after sign-off: `shapemation.builder.mode.portrait.svg`,
  `.output.portrait.svg` (+ a new `.output.frame.portrait.svg`) — ⚠️ rows in
  the INDEX files now.

## 7. Acceptance on the corpus

On the mixed pool (`tools/shapesynth/work` or the scratch projects): at
σ = 0 every placed truth lands on its target to < 0.5 px at every t; the
feasibility table names the near photos as `short` at a small face size and
the far ones as `upscaled` at a large one; the approach framing on
`city.clear.approach` renders a clip in which the face grows smoothly —
unflagged when the end key follows the subject (18 % centred → 65 % at
x 0.67, `--face-end 0.67,0.55@0.65`), while a centred 18 % → 50 % flags the
five right-drifting photos `short` on the right (the flag doing its job;
`output-frame-report.md` §2–3, which also shows `short` is aspect-driven —
a portrait source is short from ~9 %); the square 1080×1080 with the face
drifting left → centre → right renders the brief's own example.

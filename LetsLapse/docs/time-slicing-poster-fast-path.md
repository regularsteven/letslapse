# Time-slice poster fast path — implementation plan

**Raised:** 2026-09-02 (Steven, in conversation) ·
**Status: planned, not started.** Companion to `time-slicing.md`; §2 of that
plan is the decision this one carves an exception out of.

**The ask.** When a time slice is armed with *Output = Image* and *Include
regular timelapse* off, the run should not blend and encode the whole shoot.
A poster needs one master frame per band (or per grid cell), so only those
frames should be produced — **still blended at the chosen depth** (a 1:1
depth is the only case with nothing to blend), everything else skipped.

---

## 1. What an image-only slice costs today

The slicer is deliberately the *last tail pass over the finished blended
clip* (`time-slicing.md` §2). For a stills shoot with Image-only output and
the regular clip off, `startProcessing` (`AppModel.swift`, the `.photos`
case) therefore runs:

| Stage | Work | What the poster actually uses |
|---|---|---|
| Blend | every kept still decoded, graded and accumulated; M master frames encoded to a temp H.264/HEVC file | S master frames (S = segments, or columns × rows for a grid) |
| Verify | `RenderVerifier` reads the whole temp file back | nothing (the check is for video output) |
| Count | `AssetFrameProvider` makes a compressed pass over the file for an exact frame count | nothing (M is known from the schedule before any pixel is touched) |
| Slice | every master frame decoded to BGRA in order; `posterCells[master]` copies bands from S of them | the S frames |
| Clean-up | temp master deleted | — |

Two consequences beyond the wasted time. The poster passes through a
compressed generation it never needed (the doc's §2 accepts that for the
animation; for a still it is pure loss). And on iOS the master encode is
the phase that runs the phone hot and, on a long shoot, into the jetsam
territory the stacker's per-frame autorelease pool was added to survive.

**Why it is tractable on stills, and only on stills.** On the `.photos` path
every other tail pass is gated on `source.isVideo`: no canvas crop, no
reframe, no export cap, no standalone grade bake. The grade rides the
stacker (`PhotoGrader.blendSupport` on the linear path, `gradedFrameLoader`
on the gamma path), and the fine rotation and text overlays ride the
stacker's per-output-frame hook (`OverlayExportBake.stackerHook`). So a
master frame **is** "one window through the stacker plus the hook" — and one
window can be rendered on its own.

**Why the animation gets no shortcut.** Every band of every master frame is
eventually consumed by the sliced animation (band j of frame m lands in
output frame m − maxLag + lag[j]; `time-slicing.md` §1). The frames the
animation needs are all of them. This plan does not touch it.

---

## 2. The gate

The fast path takes over only when **all** of these hold at job start
(resolved with the other job inputs, never re-read mid-run):

1. `source` is `.photos` — interval and photo shoots, imported stills.
2. `timeSlice.output == .image`.
3. `timeSlice.includeRegularClip == false`.
4. `photoDepth < filteredURLs.count` — the whole-shoot stack is one image
   and already can't slice (`hasSlice` is false there; the slicing tail is
   gated on `output.kind == .video`).

Anything else — animation, both, regular clip kept, video or live-sequence
sources — runs exactly today's path. Video sources are §8, deferred.

The gate is on the *run*, not the variation: a batch inherits the baseline's
output and regular-clip choice, so a batch of image-only takes is a batch of
fast posters.

---

## 3. Architecture

### 3.1 The schedule is the master

The full render's master frame m is window m of the stacker's schedule, and
the fast path must resolve **the same schedule from the same inputs**, or its
ladder points at different photographs:

- `IntervalWarp.compile(frameSeconds:hasClock:bounds:depths:outputFPS:)`
  over the kept frames' axis seconds when the shoot has a frame axis
  (exactly the call `startProcessing` makes), else
  `WindowSchedule.make(totalInputFrames:ramp: .constant(photoDepth))`.
- Tail-frame review's `excludedFrameIndices` are removed first, the same
  `keptOrders` / `filteredURLs` derivation as today.
- M = `windows.count`, which is also `photoOutputFrameCount` — the number
  the Adjust card already quotes. A test pins the two equal.

Prefix sums over `windows` give master index → source range
`[start, start + window)`. Nothing else about the schedule (presentation
seconds, stretch shares) matters to a poster.

### 3.2 The ladder is the existing one

`TimeSliceGeometry.posterIndices(masterFrames:segments:)` for bands and
`TimeSliceGridGeometry.posterIndices(masterFrames:columns:rows:origin:metric:)`
for grids, reached through `TimeSliceRenderer.makePlan(...)` so the fast
path lays down byte-identical geometry (band rects, Bresenham remainder, the
grid's square-cell rule and edge crop, `newestEdge` mapping). `makePlan`
needs the frame size and the display transform: size comes from decoding
still 0 (the stacker sizes every stack from the first still, so the fast
path must too, even when still 0 is in no window the poster needs);
transform is identity, because `ImageStacker.loadImage` and the linear
decoder both bake EXIF orientation in — `displayOriented` becomes a no-op.

`plan.posterCells` keyed by master index is the work list. Its key set,
sorted, is the frames to render; a short master repeats frames and the
dictionary already folds those.

### 3.3 Rendering one master frame

A new Kit primitive, extracted from `stackSequenceLinear`'s loop rather than
written beside it, so the two cannot drift:

```
ImageStacker.renderWindow(
    urls: ArraySlice<URL>,            // one window's stills
    sourcePosition: Double,           // (inputIndex − window/2) ÷ (count − 1), as today
    decodeLinear: (URL) throws -> MTLTexture,
    outputGrade: ((MTLTexture, MTLCommandBuffer, Double) throws -> MTLTexture)?,
    overlayComposite: ((CVPixelBuffer, Double, CVPixelBufferPool) throws -> CVPixelBuffer?)?,
    into pool: CVPixelBufferPool, policy: VideoEncodePolicy
) throws -> CVPixelBuffer
```

Accumulate → `finalizeMean` → grade hook at the window's centre position →
`encodeGamma` with the profile's dither and gamut → colour tag → overlay
hook (which is where the level and the text go on, once per output frame —
never per input; `renderForBlend` strips the rotation for exactly this
reason). `stackSequenceLinear` then calls the same primitive per window and
appends the result to its writer. The gamma-domain legacy path
(`stackSequence`, `linearLight == false`) gets the equivalent factoring over
`accumulateImages` → `readImage` → `SceneAwareCompositor.bakeStill`; if its
`bakeStill` crop-on-rotation changes the pixel size where `bakeExportFrame`
does not, the gamma fast path routes through the pixel-buffer hook as well —
the poster must be the master's size.

The pool is the fast path's own (`CVPixelBufferPoolCreate` with the policy's
pixel-buffer attributes); there is no writer to borrow one from. Each window
runs inside an `autoreleasepool` — the 55 MB-per-frame Core Image residue
measured 2026-08-31 applies here unchanged.

### 3.4 Poster rendering entry

The current `TimeSliceRenderer.render` walks every master frame through an
`OrderedFrameProvider`. The fast path adds, in the Kit:

```
public protocol IndexedFrameProvider: AnyObject {
    var frameCount: Int { get }            // M, from the schedule
    var transform: CGAffineTransform { get }
    func frame(at index: Int) throws -> TimeSliceFrame
}

TimeSliceRenderer.renderPosters(
    provider: IndexedFrameProvider,
    recipes: [TimeSliceSettings],          // one, or a whole batch
    posterURLs: [URL],
    posterMetadata: [CFString: Any]?,
    progress: ((Double) -> Void)?
) throws -> [TimeSliceRenderResult]
```

It builds one plan per recipe, takes the **union** of their poster indices,
walks that union once in ascending order, and copies each frame's bands into
every recipe's poster buffer (`copyBandDirect`, the existing routine). Then
`makeImage` → `displayOriented` → `ImageExporter.write` per recipe, as today.
`wrotePoster`, `width`, `height`, `grid` and `maxLagFrames` fill the same
result struct so the app's registration code is reused verbatim.

Poster buffers are `width × height × 4` bytes each — ~49 MB at 12 MP. Eight
variations is ~390 MB, fine on the Mac, not on a phone: the app passes the
batch in chunks that fit a per-platform budget (macOS: all; iOS: at most 4
per chunk), re-rendering shared frames across chunks rather than caching
them. Variation batches are seconds of work here either way.

The provider lives in the **app** (`StillsWindowProvider`), because the
decode and grade closures come from `PhotoGrader.blendSupport` and the
overlay bake, both app-target. It holds the schedule's prefix sums, the
kept URLs, the closures, the pool, and checks `Task.isCancelled` between
windows; the renderer's own `cancel()` flag is bridged the same way the
tail pass bridges it today.

### 3.5 Orchestration

In `startProcessing`'s `.photos` case, ahead of the
`photoDepth >= filteredURLs.count` branch:

1. Gate (§2). On a miss, fall through to today's code unchanged.
2. Resolve the schedule (§3.1), M, and the first still's size.
3. Resolve the recipes: the baseline, or
   `TimeSliceVariationGenerator.variations(plan:baseline:masterFrames:width:height:)`
   — every input it needs is now known **before** rendering, which is not
   true of the current path (it waits for the master file).
4. Progress plan: `BlendProgressPlan.make(clipFrames: [sourceFramesToDecode],
   hasStitch: false, hasGrade: false, hasSlice: false)` where
   `sourceFramesToDecode` is the union's total window size (plus still 0 if
   it is outside the union). Phase `.slicing`; status
   "Rendering N of M frames for the poster…" for one recipe, "… — variation
   k of n…" for a batch. `reportClipProgress(0, fraction:)` per still, so
   the ETA machinery works as it does for a blend.
5. Render (`renderPosters`, detached at `.utility`, cancel bridged).
6. Register each poster exactly as the tail pass does: `parameters` from
   `currentBlendParameters()` (the warp travels with it), `id`/`createdAt`
   fresh, `timeSlice = recipe`, `kind = .image`, summary
   `"\(recipe.posterDisplayName) · W×H · N of M frames rendered"` plus the
   grid note. The first variation fronts the result screen. Poster EXIF/GPS
   carry over from the first source frame, as today.
7. No temp master, nothing to verify, nothing to clean up but the poster
   scratch files `storeBlend` copied.

`openBlend` rehydration is unchanged: a fast poster re-opens with its recipe
armed and, if the gate still holds, re-renders through the fast path.

---

## 4. Cost model

Let N = kept stills, D = depth, S = poster cells, U = distinct master
frames the ladder needs (U ≤ S; U = S once M ≥ S).

| | Stills decoded + accumulated | Frames encoded | Frames re-decoded | Full-file reads |
|---|---|---|---|---|
| Today | N | M = ⌈N ÷ D⌉ | M | 2 (verify, count) |
| Fast path | ≤ U × D (+1 for sizing) | 0 | 0 | 0 |

Worked cases, S = 24 bands, one recipe:

| Shoot | Depth | Today | Fast path |
|---|---|---|---|
| 350-frame dawn shoot (the §3 E2E) | 1 | 350 decodes + 350 encodes + 2 reads + 350 decodes | 24 decodes |
| same | 8 | 350 decodes + 44 encodes + 2 reads + 44 decodes | 192 decodes |
| 1,587-frame 12 MP library blend | 10 | 1,587 + 159 + reads + 159 (the slice pass alone measured 72.6 s) | 240 decodes |

The fast path is never slower: when U × D ≥ N it decodes every still the
full path would, and still skips the encode, the reads and the re-decode.
On iOS each depth-1 decode of a DNG is a real RAW decode, so the S-decode
case is the one to time on a phone; it is still S decodes rather than N.

Fidelity: a fast poster is composed from the accumulator's own output, not
from a decoded H.264/HEVC frame of it. It is therefore **not bit-identical**
to today's poster — it is the better image, by one compressed generation.
The verification in §7 measures rather than assumes this.

---

## 5. What does not change

- Animation and Both outputs; any run with the regular clip on; the
  whole-shoot stack; the `slicing` tail pass and the `lapse slice` CLI.
- The processing loader (`time-slicing.md` §6a, not built). Its band decodes
  at ladder positions are the same sampling idea as §3.2; when it is built
  it should take its indices from the same prefix-sum mapping.
- Manifests: `timeSlice` on the poster, `variation` stamps, naming
  (`timeslice-poster-…`). An old poster decodes identically.

---

## 6. UI

Code-first, mirrors after sign-off, per the standing sequencing decision.

- **Adjust, time-slicing card.** With *Output = Image* the readout gains a
  cost line: *"Poster only: renders 24 of 350 frames"* when the regular
  clip is off; *"Poster + regular timelapse: blends all 350 frames"* when it
  is on. The CTA already reads "Create time-slice poster" in the gated case.
  **Open question for Steven (§9):** should choosing Image flip *Include
  regular timelapse* off? Recommendation: no silent flip — the line above
  makes the cost visible and the toggle stays the user's.
- **Processing.** Phase label per §3.5; checklist row unchanged (`.slicing`
  already maps to Encoding — revisit if the row reads wrong for a run that
  encodes nothing).
- **Project detail.** Badge and version copy unchanged ("Time-slice poster"
  / "Grid poster"); the summary's "N of M frames rendered" is the only
  visible trace of the shortcut, and it is deliberate — a re-render should
  be explainable from the manifest.
- **Mirrors:** `iOS/adjust.timeslice` state (the readout line),
  `iOS/processing.portrait.svg` if the label changes, INDEX rows.

---

## 7. Build stages

1. **Kit — window primitive.** Extract `renderWindow` from
   `stackSequenceLinear` (and the gamma equivalent); re-run the existing
   stacker tests — the refactor must be byte-stable on the sequence output.
2. **Kit — `IndexedFrameProvider` + `renderPosters`.** Tests on synthesized
   stills (N solid PNGs whose value encodes the index): each band's value
   equals the mean of its window (blending is proven, not assumed); a
   single-recipe render matches the existing `render`'s poster over a master
   synthesized from the same windows, geometry byte-identical; a batch's
   union walk yields the same posters as rendering each recipe alone; short
   masters repeat frames; grid plans lay down the same layout as the tail
   pass; still-0 sizing when still 0 is outside the union.
3. **CLI — `lapse poster <stills…> --depth D --segments S [--grid corner]
   [--variations n] -o out.png`.** Same primitive, no app, so the Mac shell
   can time it against `lapse blend` + `lapse slice --poster` on the real
   library before any app wiring — the blend-first tradition.
4. **App — orchestration.** §3.5, `StillsWindowProvider`, the gate, the
   progress plan, cancel, registration. A test that the fast path's M equals
   `photoOutputFrameCount` for constant depth and for a compiled interval
   warp with exclusions.
5. **App — UI.** §6 readout line and phase label; mirrors after sign-off.
6. **Verification.** On the Mac against the 350-frame dawn shoot and the
   1,587-frame library blend: fast poster vs full-path poster (PSNR, and the
   band ladder through `tools/timeslice_report.py` on the poster's bands —
   expect identical ladders, sub-codec-noise pixel differences); a timing
   table for depth 1 and depth 8; a 4-variation image-only batch registering
   four posters and no regular clip. Then one iPhone run at depth 1 with
   DNGs, for the RAW-decode-per-band number and the thermal picture.

---

## 8. Video sources — deferred, and why

`.video` and `.liveSequence` blend through `VideoBlender` (Mac:
`MacVideoJobRunner`, concurrent and out of order) and then crop, reframe and
grade the finished file; mixed-resolution ramp shoots normalise per segment
before the stitch. A fast poster there needs a seeking provider (an
`AVAssetReader` per window `timeRange`, or `AVAssetImageGenerator` at zero
tolerance) and a per-frame version of the geometry and grade chain that
today only exists as whole-file passes. It is a second job with its own
plan; the gate in §2 keeps those sources on the current path so nothing
regresses meanwhile.

---

## 9. Decisions needed (Steven)

1. Does picking *Output = Image* flip *Include regular timelapse* off, or
   only show the cost line? (Recommendation: cost line only.)
2. iOS poster-buffer budget for image-only batches — chunks of 4, or a
   byte budget derived from `ProcessInfo.physicalMemory`?
3. Is the `lapse poster` CLI wanted, or is the Kit test suite enough
   Mac-side proof before the app wiring?
4. Accept that fast posters are not bit-identical to tail-pass posters (one
   fewer compressed generation) — this also means a poster re-rendered with
   the regular clip toggled on will differ at the codec-noise level.

---

## 10. Traps to carry in

- **Schedule drift.** The stacker's `resolvedSchedule` validates that custom
  windows sum to the input count; the fast path must build its windows from
  the identical inputs (kept URLs after exclusions, sidecar seconds, the
  active warp's bounds and depths, output fps) or the ladder samples the
  wrong photographs while looking right.
- **Keyframed grade position.** The hook's position is the window's centre
  as a fraction of the whole kept sequence, quantised to 512 steps — pass
  exactly what `stackSequenceLinear` computes, not the master index ÷ M.
- **`.cirawFilter` with a keyframed grade** is forced back to Bradford inside
  `blendSupport`; reuse `blendSupport`, do not rebuild the closures.
- **Rotation once.** Level and overlays go on in the per-output-frame hook;
  `renderForBlend` strips rotation on purpose. A fast path that rotates the
  inputs as well turns the picture twice.
- **Sizing from still 0** even when it is outside the union — otherwise a
  shoot whose first frames differ in size from the rest sizes the poster
  differently from the master it claims to represent.
- **Autorelease per window** — the jetsam measurement stands.
- **Don't cache decoded master frames across variations** in RAM; walk the
  union once and write into per-recipe buffers (§3.4). The same arithmetic
  that ruled out RAM for the animation applies at 12 MP.

# Guided builder: low-fidelity previews before Create — proposal

Steven's ask (2026-08-12): every step of the Guided clip flow should let you *see*
what you are about to render, cheaply, before committing to a multi-minute
"Create X s clip". Scrubbing on the preview surface for Canvas & Opening, a
framing-aware motion preview on Moments, an arrival-aware preview on Ending,
and a storyboard on Review. This document is the design proposal; nothing here
is implemented yet.

The designer brief's hard rules still bind every idea below
(`guided-builder-designer-brief.md` §1): exact frames under framing tools,
one output-seconds clock, the number on screen is the number that renders, no
keyframe escape hatch. The brief explicitly reserved a home for a motion
preview ("a separate, known effort") — this is that effort.

## 0. The honest backbone (shared by all four steps)

Every preview is driven by the same three pieces the *render* uses, so the
preview cannot drift from the output the way a hand-rolled approximation would:

1. **The compiled frame map.** `model.compiledWarp()` (AppModel.swift,
   memoized) yields `frameSourceTimes` — the exact source moment each output
   frame will show, seam eases and slow-motion floors included. A scrub
   position in *output seconds* (the flow's only clock) indexes straight into
   it. This is the same map the reframe bake consumes, which after the
   2026-08-12 density fix is also exactly what the blend engine emits.
2. **The materialised track.** `GuidedPlanner.track()` already produces the
   real `ReframeTrack`; `track.frame(atSource:outputTime:)` evaluates the
   framing — punch, pan, move spans, ease vs thru — with the *render's own
   interpolation code* (the pattern `ReframeCanvasView` already uses).
3. **The scrub-friendly loader.** `WarpPreviewLoader` (1024 px, ≈keyframe
   tolerance, 90 ms debounce, keeps the last image while decoding) is the
   fast path; `warpFrameLocation(at:)` maps source time → (file, seconds).
   The existing "≈ keyframe preview" badge idiom marks the fidelity honestly.

What the low-fi preview deliberately does NOT show: blend streaks (a single
decoded frame can't carry a 100× stack). The pane says so with the ≈ badge; a
later enhancement can composite ~3 neighbouring frames after the scrub settles
to hint the streak, but v1 keeps every sample to one decode. Framing *editing*
stays on `ExactFrameLoader` surfaces — the scrub preview is never the surface
a crop is composed on.

## 1. Canvas & Opening — scrub the opening

- The stage (`GuidedCanvasFrame` pane) gains a scrub affordance across the
  opening stretch's slice of the output clock, **including its outgoing seam
  ease** so you feel the hand-off into Moment 1.
- **macOS / iPad rail:** pointer hover over the stage scrubs (precedent:
  `onContinuousHover` already lives in this view for the grab cursor). A thin
  output-proportional progress line under the stage shows where you are; an
  output-clock chip ("0:02.3 of 0:03.5") uses the compiled numbers.
- **iOS column:** the pane's drag currently repositions the crop, so scrubbing
  arms explicitly — a small `Preview` chip beside the pane (see §2's mode
  grammar); while armed, horizontal drag scrubs, and the crop-offset drag is
  masked. Disarms on step change.
- Changing the OPENING speed chip re-compiles and the same gesture instantly
  reflects the new pacing — that *is* the feature: 15× vs 100× feels different
  under the finger because the output window remaps.

## 2. Moment — Start framing · End framing · Preview

Steven's grammar, adopted directly: alongside the existing framing-target
chips (`Start framing` / `End framing`, GuidedBuilderView `framingTargetChips`)
a third mode: **Preview**.

- In Preview mode the stage stops being the framing box and becomes the
  *output* through the moving crop: each scrub sample evaluates the
  materialised track at that output moment and shows the cropped picture the
  finished clip will show — the punch riding the arriving ramp, the pan
  (thru = linear vs eased = cubic, exactly as authored), and the release.
- Scrub span: from just before the arriving seam ease to just past the
  departing one, so both welds are visible — the whole answer to "what will
  this moment look like".
- A burst moment at ¼×/½× is effectively a scrubbed playback of the real
  slow-motion frames — cheap and honest (no blending in the preview; the ≈
  badge covers the ramp's blend). A hard cut needs nothing extra: the scrub
  simply jumps where the cut jumps.
- Tapping `Start framing` / `End framing` returns to the exact-frame box for
  a quick correction — one tap between "see it" and "fix it".
- macOS: hover scrubs whenever the stage is in Preview mode; the framing modes
  keep their existing cursor/scroll-wheel grammar untouched.

## 3. Ending — arrival-aware scrub

Same surface as §1, but the scrub span **starts before the arriving seam**
("How it arrives" is the step's first card, so the preview must show that
arrival: the speed ramp and the release-to-wide riding it together). With the
density fix in place the compiled map is truthful here — this preview would
have made the ends-punched bug visible in the builder instead of after a
multi-minute render.

## 4. Review — storyboard + full-clip scrub

The review step is today the only step with no visual surface. It gets two:

- **Stage: the whole-clip scrubber.** One strip, whole output timeline,
  same backbone — the last look before Create. The stage shows the
  track-cropped output picture; the strip underneath is output-proportional
  with the moments marked (the macOS overview strip's visual vocabulary,
  ink/amber blocks + seam connectors).
- **Storyboard under it: "a super simple set of images".** One group per
  stretch: wide stretches get start → end thumbnails; punched moments get
  start → middle → end with arrows between cells (the middle shows the pan
  actually travelling). Seam connectors between groups carry the compiled
  labels the review rows already use ("cut", "1s", "2s ease"). Cells are
  one-shot ≈keyframe decodes cropped through the track — cacheable, loaded
  once per review visit, and each cell is clickable to jump back to its step
  (the overview strip's established behaviour).

## 5. Performance envelope

- One decode per scrub sample, 1024 px, keyframe-tolerant — the loader
  already debounces drag storms to the last request. Target: a sample lands
  in well under 100 ms on device; stale image holds in between (no black
  flashes — `WarpPreviewLoader` semantics, not `ExactFrameLoader`'s nil reset).
- Small LRU of decoded frames keyed by (file, rounded seconds) so scrubbing
  back and forth over a moment is instant after the first pass. Storyboard
  cells reuse it.
- Optional pre-warm: when a step opens, decode ~6 samples across its span in
  the background (cancellable, MediaWorkQueue) so the first scrub feels live.

## 6. Design-sync footprint (per the README contract)

- iOS: all four step SVGs gain the preview affordances
  (`guided-builder.canvas.portrait.svg`, `.portrait.svg`,
  `.closing.portrait.svg`, `.review.portrait.svg`); scrub-in-progress can be a
  desc-only state, the Preview chip and storyboard are drawn.
- macOS: the three rail SVGs likewise; the review step likely earns a real
  `macOS/guided-builder.review.svg` (storyboard + scrubber diverge from the
  iOS column enough that the 🟡 shared-spec row stops being honest).
- iPadOS: stays a shared-spec row over the macOS files (touch scrubs, no
  hover), notes updated.
- INDEX rows for every touched file, same commit as the implementation side.

## 7. Open questions

1. Design-first (SVGs → sign-off → code) or app-first (build → verify →
   mirror)? The flow's history has both precedents.
2. Is the Review full-clip scrubber v1, or does v1 ship the storyboard only
   and the scrubber follows? (The storyboard alone already delivers "see it
   before Create"; the scrubber is the delight layer.)
3. Settle-composite streak hint (3-frame blend after the scrub pauses):
   worth the extra decode cost, or does the ≈ badge suffice?

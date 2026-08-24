# Giving interval shoots the video "New blended clip" screen

**Raised:** 2026-08-24 (Steven) · **Status:** Phases 1 and 2 implemented
2026-08-24 (phase 2 code-first per Steven — SVG mirrors follow sign-off).
See the phasing section for what landed and what each later phase still
needs. Phases 3–4 open; each starts with the design-sync question.

The ask: the video-capture configure screen (warp timeline, speed stretches,
ramps, punch-in reframe, canvas, fps/estimate card) should serve interval
shoots too, and the restricted interval variant should eventually retire.

## One premise to correct first

> "It's used on the Photo capture, so that should remain."

**Photo captures never reach this screen.** Photo mode returns before
`setSource` ([CaptureView.swift:869-885](../App/CaptureView.swift)) and photo
projects are routed to `photoActions` in project detail
([ProjectDetailView.swift:444-451](../App/ProjectDetailView.swift)); the
Projects list hides the "+" tile for them too. The restricted branch's real
consumers today are **Interval and Scanner** captures. So the phase-out
question is not "Photo still needs it" — it is "what must the rich screen
absorb from it before the `.photos` branch can go", and "where does Scanner
get diverted to".

## Verdict

**No risk to the video paths — every change is additive on the stills side —
but this is not a screen swap; it is a real project.** The screen fork is the
visible tip of a source-model fork: `.photos` sources have no duration, no
fps, no pixel dimensions, no AVAsset, and (for basic interval shoots) no
timestamps sidecar at all. The good news: the underlying unification is
conceptually clean, because **the warp timeline's window schedule and interval
blend depth are the same idea** — frames-per-output-frame — so the rich UI
can absorb the restricted screen's controls rather than losing them.

## What actually blocks it today (all measured, file:line)

1. **No time axis.** `blendStretches()` returns `[]` for `.photos` and
   `sourceDurationSeconds` is never set for stills → a zero-length warp
   timeline ([AppModel.swift:2339-2361, 5372-5373](../App/AppModel.swift)).
   Worse: **a basic `Interval · JPEG` shoot writes no `frames.timestamps` at
   all** — only Holy Grail and Scanner runs write the sidecar
   ([CameraController.swift:5809](../App/CameraController.swift)) — so those
   projects have frame counts only.
2. **The preview loader is movie-only.** `WarpPreviewLoader` is
   `AVAssetImageGenerator` over `AVURLAsset`
   ([WarpTimelineView.swift:10-47](../App/WarpTimelineView.swift)). A stills
   twin exists in embryo: `PhotoViewerView`'s coarse-ladder scrubber already
   maps position→frame index and even switches its axis to elapsed capture
   seconds from the sidecar ([PhotoViewerView.swift:158-299](../App/PhotoViewerView.swift)).
3. **The stackers don't take a compiled schedule.** Neither
   `ImageStacker.stackSequence` variant accepts `customWindows`; both build
   their own `WindowSchedule` internally
   ([ImageStacker.swift:222, 391](../Kit/Sources/LetsLapseKit/ImageStacker.swift)).
   The compiled shape (`WarpCompiler.Compiled.schedules`) matches the internal
   one, so the plumbing is small — but a stills `SourceRegion` concept has to
   exist first.
4. **Speed semantics invert.** `WarpCompiler` floors speed at one source frame
   per output frame (`floorSpeed = outFps / regionFps`,
   [WarpTimeline.swift:355-361](../App/WarpTimeline.swift)). Interval footage
   at 1 frame / 3 s against 25 fps output has a 75× floor — every chip below
   75× is unrenderable in the compiler's current terms. The timeline needs an
   interval vocabulary (frames-per-output = blend depth; "slower" = shallower
   stacks, "faster" = deeper/skipped), which is exactly how the restricted
   screen's blend slider should be absorbed.
5. **Geometry + grading are derivable but absent**: `sourceWidth/Height`
   never probed for stills (canvas/reframe need it); keyframed grades ride a
   per-index map on stills vs `GradeSourceMap` from `frameSourceTimes` on
   video — reconcilable once a compile exists. The gamma stills path also
   hardcodes H.264 ([ImageStacker.swift:248-249](../Kit/Sources/LetsLapseKit/ImageStacker.swift));
   only the linear path honours the codec chooser.

## What transfers for free

The video-only tail passes gate on `output.kind == .video`, and a stills blend
already **produces** a `.mp4` `ProcessingOutput` — so reframe bake and canvas
crop are structurally reusable the moment the inputs resolve
([AppModel.swift:3342-3359, 3508, 3562](../App/AppModel.swift)). The bottom
bar, estimate card, and fps menu carry over unchanged.

## Suggested phasing (when this becomes a job)

1. **Enablers, invisible — DONE 2026-08-24:** every interval-style run writes
   `frames.timestamps` (plain photo-timer runs via `intervalWriter` in
   `CameraController`; blend runs via `writesFrameTimestamps` in both blend
   controllers' configurations — off for Holy Grail, whose ramp owns the file;
   Scanner untouched). Stills projects get `sourceWidth/Height` (oriented,
   metadata-only) and a sidecar-derived `sourceDurationSeconds` from
   `AppModel.refreshStillsMetadata` — at registration, at `.lapse` import, and
   in a one-shot `loadLibrary` catch-up gated on missing dimensions. The
   shared axis is `FrameAxis` in the Kit (tested; the photo editor's scrubber
   now maps through it) with `FrameTimestamps.elapsedSeconds(coveringExactly:)`
   as the one coverage gate, and `StillsPreviewLoader` staged beside
   `WarpPreviewLoader` for the timeline to adopt. Kept invisible on purpose:
   `formatBadge` and the Adjust header stay kind-gated, so the new fields
   change no screen until phase 2 chooses to. One behavioural effect is
   deliberate: fresh plain-interval blends now lay out on the real capture
   clock (`ImageStacker` already honoured a covering sidecar); even pacing
   maps to the constant layout, uneven pacing now renders honestly.
2. **The timeline — DONE 2026-08-24 (code-first; SVGs after sign-off):**
   interval shoots get the real warp timeline in the interval vocabulary —
   a stretch's "speed" is its blend depth (photos per output frame, labelled
   "5:1"), which is the old whole-shoot BLEND slider absorbed as chips
   (1:1 crisp … 8:1, custom sheet to the frame count). The pieces:
   - **Axis**: `AppModel.stillsFrameAxis()` (cached `FrameAxis` — sidecar
     seconds / uniform span / frame units; `healWarpAxis` uniform-rescales a
     saved timeline whose axis has since been probed). `warpVocabulary`
     routes every label in `WarpTimelineView` (clock vs "N fr", `depthLabel`/
     `depthWord`, amber shading = depth 1, seam pills suppressed — interval
     seams are steps by construction).
   - **Compiler**: `IntervalWarp.compile` in the Kit (frame-exact walk:
     window depth = the stretch its first frame falls in; trivial timeline ≡
     `WindowSchedule.make`, tested). Presentation times are per-stretch
     proportional on the capture clock — a depth change re-paces the clip
     while phase 1's honest layout survives inside each stretch, and an
     unedited timeline renders bit-identically to the pre-timeline path.
   - **Render**: `stackSequence`/`stackSequenceLinear` take
     `customWindows`/`customWindowTimes` (validated to cover the inputs;
     compiled schedules own their pacing — the sidecar never re-stretches an
     authored warp). The job compiles against the KEPT frames, so tail
     exclusions hold their moments. The warp rides the blend recipe; keyframed
     grades were already source-anchored in the stacker, so they track.
   - **Screen**: stills Adjust = source card, tail banner, timeline + depth
     chips, "One long exposure" mode row (the whole-shoot stack), unified
     estimate card ("303 photos → 101 frames", before/after bar), Advanced
     (True-light + excluded-frames; Ramp/Trim stay video vocabulary — the
     Advanced ramp is deliberately NOT honoured for stills). Wide layout now
     serves stills too (preview pane beside the timeline).
   - **Verified**: Kit tests (8 `IntervalWarp` cases + suite), all three
     platform builds, and a headless Mac E2E on the real library
     (`LL_ADJUST=stills` + `LL_STRETCH="0=3"` + `LL_ADJUST_CREATE=1`):
     303-photo sidecar shoot → 101 frames, 4.04s @ 25fps, "timed from
     capture", warp in the recipe. Screenshots: Mac wide + iPhone narrow at
     depths 1 and 5.
3. **Spatial + grade:** reframe/canvas on stills renders; grade-map
   unification; codec chooser on both stills paths.
4. **Retire the `.photos` branch** — after Scanner captures are diverted to
   their own configure surface (they already have their own detail screen and
   export path).

Each UI phase is a design-sync unit (design-first vs app-first to be asked at
the start, per [design/README.md](design/README.md)).

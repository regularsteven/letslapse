# Audit — `letslapse-app-overview.md` vs. the shipping code

**Date:** 2026-08-10 · **Basis:** working tree of `ios-app` at `63c1c23` (clean), source read of `LetsLapse/App/`, `LetsLapse/Shared/`, `LetsLapse/Kit/`, and `docs/design/`; every claim is traceable to a file and line. Parts A–D were written from source alone. §A3b and the design-mirror work that followed were verified on the **iPhone 16 simulator** (393×852, Debug build) — including driven pinch, drag-to-nominate, canvas-drag and rotation — and those captures confirmed the code reading rather than amending it.

**Question asked:** can `letslapse-app-overview.md` be handed to a developer as a faithful description of the app? Particular concern: the **New blended clip** screen and **Punch-in reframe**.

**Verdict:** **Not yet.** The document is excellent on everything up to about 2026-08-01 — capture, the blend engine, DNG, grading, geotagging, the watch, Collections. But the single most-edited screen in the app, **Adjust / "New blended clip", was rebuilt twice since the doc was written and the doc still describes the version before both rebuilds.** The words *warp*, *stretch*, *reframe*, *punch* and *canvas* (in the Adjust sense) appear **zero** times in 817 lines. A developer handed this doc would open `AdjustView.swift` and find nothing they had read about, and two of the doc's stated design principles (§2.6 "No editing timeline required", §10 "no keyframe editing (deliberate)") are now the opposite of what ships.

Three sections need rewriting (§4.4, §3.2/§3.3, §9), five need edits, and one product area — Punch-in reframe — needs a written specification before it is handed over at all, because its current behaviour is under-specified in code comments and materially surprising in use (Part C).

---

## Part A — Document vs. code

### A1. Missing entirely

| # | Feature in the code | Where it lives | Doc coverage |
|---|---|---|---|
| 1 | **The warp timeline** — Adjust rebuilt as design 3a: the source partitioned into *stretches*, each with a speed in ×-real-time; drag-to-nominate a real-time moment; *seams* own the ramps (step / 0.5s / 1s / 2s + which side spends the time); scrubbable playhead with keyframe preview; pinch zoom with a 20 s floor, minimap, Fit chip; resize handles with ripple; hold (or right-click) stretch menu; a 30-deep undo history bridged to Cmd-Z / shake | `App/WarpTimeline.swift`, `App/WarpTimelineView.swift` (1,334 lines), `AppModel.updateWarp` / `undoWarp` (`AppModel.swift:1531`) | **none** |
| 2 | **`WarpCompiler`** — compiles stretches + seams into per-output-frame window schedules, sampling the speed curve (16-step smoothstep per ease), and emits the output-frame → source-moment map | `App/WarpTimeline.swift:265-436` | **none** |
| 3 | **`VideoBlendOptions.customWindows`** — the Kit input the compiler drives; it is now the normal path for any video blend | `Kit/Sources/LetsLapseKit/VideoBlender.swift:50,256` | **none** (§3.2/§3.3 describe only `BlendRamp`) |
| 4 | **Punch-in reframe** — spatial keyframe track, interactive punch canvas, lane, and a per-frame crop render pass | `App/ReframeTrack.swift`, `ReframeCanvasView.swift`, `ReframeLaneView.swift`, `ReframeVideoCropper.swift`, `AppModel.swift:2307-2421` | **none** |
| 5 | **Adjust canvas ratio** — the header menu that picks the clip's output shape (16:9 · 9:16 · 1:1 · 4:3 · 3:4), and the static centre-crop pass that bakes it | `AdjustView.swift:202-242`, `App/VideoCanvasCropper.swift`, `AppModel.swift:2426-2454` | **none** |
| 6 | **Five `BlendProject` recipe fields** — `warp`, `reframe`, `canvasRatio`, `stretchWindows` (legacy decode), `defaultCrops` | `AppModel.swift:221-240` | §4.13's model list names none of them |
| 7 | **Apple Vision as a built-in analyser** — zero-download catalog entry (`engine: "vision-framework"`), the "On this device" section, silent one-frame tagging at capture time | `App/AI/ModelManager.swift:29,60`, `AIModelsView.swift:28`, `App/AI/VisionSceneAnalyzer.swift` | §7a describes only the MLX path |
| 8 | **Branded loading states** — launch splash (`LaunchAnimationView`, `LLRigMark`, the `UILaunchScreen`/`LaunchBackground` Info.plist arrangement) and the 120 pt `LLRigProgress` gauge that replaced Processing's plain ring | `App/LaunchAnimationView.swift`, `LLRigMark.swift`, `LLRigProgress.swift` | none (§4.9 still describes "circular progress ring") |
| 9 | **Burst status indicator** and the Projects card's source line ("4 source clips · 2 bursts at 120 fps") | `App/BurstStatusIndicator.swift`, `ProjectsView.swift` | partial — §4.3 mentions "a segment strip" only |
| 10 | **Shared swipe-to-delete** modifier and the project-detail reorder (results first) | `App/SwipeToDelete.swift`, `ProjectDetailView.swift` | none |

### A2. Statements that are now false

| # | Doc says | Code says |
|---|---|---|
| 11 | §2.6: *"**No editing timeline required.** The ramp is a simple parametric function (start, end, curve) rather than a keyframe UI — by design."* | There are now **two** keyframe/timeline editors on the Adjust screen: the warp timeline (temporal) and the reframe lane (spatial). The parametric ramp survives as a legacy option behind Advanced, and editing the timeline **switches it off** (`AppModel.swift:1550`) |
| 12 | §10: *"no keyframe editing (deliberate)"* | Same. This is the most misleading single line in the document for a new developer |
| 13 | §8 vocabulary: collections are *"upcoming … a placeholder tab today"* | Shipped 2026-08-01; §4.1 of the same document describes the shipped feature. The two sections contradict each other |
| 14 | §10: *"Processing checklist stages are **cosmetic** — derived from progress thresholds, not real pipeline phases"* | §4.9 of the same document says the opposite, and §4.9 is right: `AppModel.processingPhase` is set explicitly by the pipeline. §10's bullet is a leftover |
| 15 | §4.4 table: speed chips *10× / 25× / 50× / 100×*, character words *gentle → trails*, seeding `BlendRamp.constant(window)` | Chips are **¼× · 1× · 4× · 15× · 60× · 100× · ···custom** (`AdjustView.swift:35-38`), they are ×-real-time, and they edit **the selected stretch**, not the clip |
| 16 | §4.4 table: *"**Slow-motion ramp** menu (Default / Off / 0.25 s → 2.0 s)"* on the Adjust screen | That row no longer exists in `AdjustView`. The project/app default is now **seeded into the warp's seams** (`AppModel.swift:1666-1669`) and only the legacy path still stitches with `BurstRamp`. The Settings → Video default and "Remember last" are unchanged |
| 17 | §3.2 fork table | Needs a warp row: on macOS a **warped** blend runs in-process through `VideoBlender`, *not* the disk-backed job runner — the runner only speaks constant windows (`AppModel.swift:2640`) |
| 18 | §4.1 state diagram: `configure → processing` etc. | Still correct, but `configure` is now a substantial editor with its own undo stack that is cleared on flow exit (`clearWarpHistory`, `AppModel.swift:1641`) — worth a sentence |

### A3. Factual drift (small, but it is orientation data developers navigate by)

| Doc | Actual |
|---|---|
| `App/AppModel.swift` "~3,261-line source of truth" (§9) | **4,697** lines |
| `App/CameraController.swift` (~2,748) (§4.3, §9) | **3,498** |
| `App/CaptureView.swift` (~2,933) (§4.3, §9) | **3,109** |
| `App/ProjectDetailView.swift` (~1,777) (§4.10) | **1,927** |
| §3.4 "**18 test files**" | **19** — `BlendProgressPlanTests` is not in the grouped list (it is mentioned in §4.9) |
| §9 hooks table | Missing `LL_ADJUST`, `LL_STRETCH`, `LL_CANVAS`, `LL_REFRAME` (+`_SEED`, `_RATIO`, `_RENDER`), `LL_COLLECTIONS`, `LL_BURST` (+`_MODE`), `LL_LAUNCH`, `LL_RESET_CAPS`. The "suppresses the auto-open camera" note should point at the `hookKeys` list (`LetsLapseApp.swift:245`), which is the real contract |
| §10 test gaps | Should now name `WarpCompiler`, `ReframeTrack`/`ReframeMath`, `ReframeVideoCropper`, `VideoCanvasCropper`, and `VideoBlender.customWindows` — **all untested, all on the critical render path** (no Kit test references any of them; there is no app-layer test target) |

### A3b. The design mirrors for Adjust (added 2026-08-10, after the first pass)

Checked on request: **there is no Punch-in reframe SVG anywhere in `docs/design/`** — no file on any platform, and no existing SVG contains the feature. The three reframe rows in `iOS/INDEX.md` (lane open · draft framing · wide) have always been 🟡 with "Awaiting sign-off, then draw the SVGs", so this is a *recorded* gap rather than a lost file — but it is still the largest un-mirrored surface in the app.

Checking that turned up a bigger one: **`adjust.portrait.svg` and `adjust.zoomed.portrait.svg` were marked ✅ Synced and are not.** Both predate the 2026-08-04 canvas/output-timeline rework and the 2026-08-06 reframe unification. Five drifts on the base spec:

1. No **canvas menu** in the header (16:9 · 9:16 · 1:1 · 4:3 · 3:4 with its "— as shot" / "— crops to W×H" rows).
2. No **Punch-in reframe** row between the chips and Blend from.
3. It still draws a **source card** ("Sunset over harbour · Change · SOURCE · 8:16") and a SOURCE header row on the warp card — the video screen has neither now; `sourceCard` is the photos branch only, and the Undo/Fit chips float over the preview instead.
4. Its bar is **source-proportional**; the shipping bar is output-proportional, so tile widths are shares of the finished clip.
5. Its ruler is the **source clock** (0:00 / 4:08 / 8:16); the shipping ruler reads clip time.

The preview is also a full-width pane now, not a thumbnail that chases the playhead.

**Resolution (same day).** All five drawings are now current, every one measured on the iPhone 16 simulator at 393×852:

| File | How it was captured |
|---|---|
| `adjust.portrait.svg` (redrawn) | `LL_ADJUST=demo` + `LL_STRETCH="0=100,2=100,4=100"`, 1 s burst-ramp default |
| `adjust.zoomed.portrait.svg` (redrawn) | same, then a driven two-finger spread on the bar and a drag-to-nominate |
| `adjust.reframe.portrait.svg` (new) | `LL_REFRAME=latest LL_REFRAME_SEED=1` |
| `adjust.reframe-draft.portrait.svg` (new) | same, then a driven drag on the punch canvas between two keys |
| `adjust.reframe.landscape.svg` (new) | same, with the sim rotated through the Simulator's Device ▸ Rotate menu (`simctl` cannot rotate, and the screenshot comes out portrait-shaped needing a 270° turn) |

One element resisted capture and is drawn from the code contract instead, stated in its `desc`: the "Added 1× stretch · Undo" toast auto-dismisses at 4 s, which outlives both a `simctl` screenshot round-trip and the pause between a driven gesture and a capture.

Two defects were left **as they render** rather than quietly corrected in the drawings, because a spec that fixes a bug silently is how the code and the spec start lying to each other in the other direction:

- The draft chips collide with their neighbours — the "Set keyframe at m:ss" capsule is an `.overlay(alignment: .bottom)` while the state badge is `.bottomLeading` and the minimap `.bottomTrailing`, so the chip covers the right half of the badge ("≈ new fram…") and the ✕ sits over the minimap's left edge.
- The move pills name viewer-seconds the clip cannot pay (below).

That capture also produced a useful piece of evidence for Part C: with the seeded track on a 1:00 source at 100×, the lane's move pills read **"~1s ease"** and **"~2s ease"** while the estimate card says the clip will be **0.6 s** long. The silent span clamp is not a theoretical edge case — it is the default reading on a first run.

Minor code note from the same check: `AdjustView.sourceSubtitle` still carries a video branch that composes "08:16 · 1080p · 30 fps · 2 moments", but its only caller is `sourceCard`, which video never renders — so the "N moments" line the design called for is currently unreachable on the video screen.

### A4. What is still accurate

Worth saying plainly, because it is most of the document: §1, §2.1–§2.5, §3.1, §3.3 (the streaming pipeline), §4.3 (capture), §4.5 (grading), §4.6 (geotagging), §4.7, §4.8, §4.11, §4.12, §4.13's directory layout, §5 (macOS, apart from the fork row), §6 (the whole DNG arc), §7 (watch) and §8's palette/typography read as written. The design-sync contract in `docs/design/README.md` and the per-platform `INDEX.md` files are **current as a record** — they track the warp timeline and the reframe lane, and the reframe rows were already flagged 🟡. In that bookkeeping sense the design folder is ahead of the handover doc, which is the reverse of the usual failure. The *drawings* themselves are another matter: the two Adjust SVGs are stale and now say so (§A3b).

---

## Part B — What the "New blended clip" screen actually is

This is the replacement for §4.4. (`App/AdjustView.swift`, 988 lines; `App/WarpTimelineView.swift`, 1,334.)

**The premise changed.** The old screen chose one number (speed) for the whole clip. The new one is a **time-warp editor**: the source is partitioned into consecutive *stretches*, each carrying its own speed in ×-real-time, and the invariant is stated in the source itself — *"this is a monotonic, continuous time-warp — never a trim. Every source frame lands in exactly one output moment; the blur window follows the instantaneous speed through every ease"* (`WarpTimeline.swift:9-11`). Nothing is ever discarded; a "slow" stretch is 1× or ¼×, not a cut.

**The bar is drawn in output time, not source time.** A 4-minute base run at 60× that lands as 4 s of a 14 s clip draws narrow; the 3-second moment that becomes most of the clip draws wide (`WarpTimelineView.swift:464-505`). This is the single most important thing to understand before reading the file — every gesture maps pixels → *clip* seconds → source seconds through the warp.

**The controls, in the order a user meets them:**

- **Header canvas menu** — the clip's output shape; defaults to the shape as shot, and each row states the consequence ("1:1 — crops to 1080×1080"). Non-matching canvases bake a centre crop after the blend (`VideoCanvasCropper`).
- **The warp card** — playhead frame preview on top (a *keyframe-tolerant* still, badged "≈ keyframe"), then the bar: stretch tiles with their speed labels, seam pills between them, the playhead knob, resize handles on the selected stretch's boundaries, a clip-time ruler that pans when zoomed, a minimap while zoomed, and the selection line ("Stretch 2 of 3 · 1:30–1:46 · ¼× slow motion → 4.2s of the clip") with a ⋯ menu.
- **Gestures**: tap a tile to select + scrub there; **drag across the bar to nominate** a new 1× stretch (minimum 2 s of source, dashed→amber overlay, warning toast if released short); pinch to zoom (20 s floor, anchored under the fingers, tick at the travel ends); double-tap to zoom in/out; hold a tile (0.45 s) — or right-click on macOS — for Remove · Split here · Reset speed; drag the ruler to pan.
- **Speed chips** — ¼× · 1× · 4× · 15× · 60× · 100× · custom, editing **the selected stretch**. "Every stretch is speedable — no separate 'base'."
- **Punch-in reframe row** — the disclosure for the reframe lane (Part C).
- **Blend from** codec chips, the estimate card (now exact: the compiled schedule's frame count, `AppModel.swift:1454-1462`), and **Advanced** (the legacy parametric ramp, trim, true-light).
- **Undo** is a first-class chip on the card, backed by `AppModel.warpUndoStack` and bridged to the window `UndoManager` so Cmd-Z / shake / three-finger-swipe all drive the same history.

**How it reaches the engine.** `WarpCompiler.compile` walks the stretches, replaces each eased seam with 16 sampled constant-speed runs that *borrow* source time from the chosen side, and emits (a) one window schedule per source region and (b) the mid-window source time of every output frame. The schedules go to `VideoBlender` as `customWindows`; the frame times are what the reframe crop is evaluated against. Window size is floored so slow motion never asks for less than one source frame per output frame (`WarpTimeline.swift:420`). The compiled timeline is memoised on its inputs (`AppModel.swift:1792`).

**Two paths still exist.** Turning on the Advanced ramp makes `compiledWarp()` return nil and the whole warp (and the reframe) is ignored in favour of `BlendRamp` — and any direct timeline edit turns the Advanced ramp back off. A developer must know that these are mutually exclusive, because the UI only whispers it (Part C, problem H).

**Photo/interval sources** keep the old screen entirely: source card, tail-frame banner, blend-depth slider. Everything above is video-only.

---

## Part C — Punch-in reframe: how it works, and where the UX hurts

### C1. What it is

A **spatial keyframe track** that rides alongside the warp timeline: `ReframeTrack.keys = [{t, z, cx, cy}]` — source time, punch factor (1…6), and crop centre in display-oriented source pixels — plus one `Move {span, curve}` per gap. Empty track = full frame. One key = one constant crop. The design decision, stated in the source: *"The two tracks are related by adjacency on the same bar, never by data"* (`ReframeTrack.swift:8`) — speed lives only in the warp, framing only in the reframe.

**Two entry points, one flow**: the "Punch-in reframe" secondary button on a video project's detail page (`ProjectDetailView.swift:326`) opens the New blended clip screen with the lane already expanded; the row inside Adjust toggles it (`AdjustView.swift:333`).

**Authoring**: with the lane open, the preview becomes an interactive canvas — pinch to punch, drag to position. On a key, gestures write the key directly. Between keys they shape a **draft** (dashed amber edge, "≈ new framing" badge) that must be committed with "Set keyframe at 1:30". The lane below draws a diamond per key on the output-proportional axis, a move pill per gap, and a key line with the explicit "+ Keyframe at m:ss" affordance.

**Moves are arrive-anchored and measured in output seconds**: the crop *holds* the earlier key's framing, then eases into the later key over the last `span` of the gap — "be locked on by here; take this long to get there" (`ReframeTrack.swift:33-37`). Span is `gap` / 0.5s / 1s / 2s; curve is `ease` (cubic in-out) or `thru` (linear, for tracking chains). Zoom interpolates log-linearly, centre linearly.

**Render**: after the blend, `ReframeVideoCropper.croppedCopy` runs one `AVAssetExportSession` pass over the finished clip with a per-frame crop, Lanczos-scaled to one constant size — the canvas-shaped base crop at source pixel scale (`ReframeVideoCropper.swift:23-29`). It subsumes the static canvas crop when both would apply.

**Persistence**: `BlendProject.reframe` + `.canvasRatio`, rehydrated by `openBlend` so a clip can be re-edited from exactly its own track.

### C2. How it composes with time blending — the part a developer must get right

1. **The crop is welded to scene time, not clip time.** Each output frame's crop is evaluated at that frame's *mid-window source moment* (`WarpTimeline.swift:423` → `ReframeVideoCropper.rects`). That is the correct and non-obvious choice: however the speed curve stretches the clock, the punch stays on the thing it was aimed at.

2. **But the move's *duration* is on the viewer's clock.** Keys are placed in source seconds; move spans are output seconds. The two axes are related by the warp, which is wildly non-uniform:
   - In a **100× stretch** at 30 fps, one output frame consumes ~3.3 s of source. Two keys placed 2 s of source apart are **less than one output frame apart** — the "move" renders as a hard cut, and there is nothing on screen that says so.
   - The span silently clamps to the gap: `span = min(move.span.seconds ?? gap, gap)` (`ReframeTrack.swift:182`). A pill reading **"~1s ease"** can render in 0.02 s and still read "~1s". Compare this with how carefully `BurstRamp` reports its own clamp ("capped to 0.62s") — the reframe has the same clamp and none of the honesty.
   - In a **¼× moment** the relationship inverts: 1 s of source is 4 s of clip, and a `gap`-span move drifts for four seconds.
   - `minimumKeySpacing` is **0.05 *source* seconds** (`ReframeTrack.swift:86`) — sane in a slow stretch, but at 100× it is 1/60th of an output frame, so two keys can be distinct on the track and identical in the render.

3. **Blur is computed before the crop, so the punch magnifies it.** The blend averages the full frame; the reframe then enlarges the result by *z*. A streak that crossed 20% of the wide frame crosses 40% of a 2× punch. Punching in therefore *amplifies* apparent motion blur — and equally amplifies handheld drift and inter-window jitter, with no stabilisation anywhere in the path. In practice a punch usually wants a slower stretch under it; the two lanes are deliberately unlinked and the UI offers no guidance at all.

4. **Preview maths ≠ render maths.** The canvas and lane evaluate moves through `WarpTimeline.outputTime`, the steady-speed piecewise approximation; the render inverts the exact compiled frame map, seam eases included. The difference is fractions of a second and is documented in comments — but it means the preview is structurally an approximation of an approximation (see problem A).

5. **It is a second full re-encode.** Blend → H.264 intermediate → crop + Lanczos upscale → re-encode (`AVAssetExportPresetHighestQuality`) → optionally a *third* encode for the grade bake. The punch magnifies already-compressed 8-bit pixels; at 6× on 1080p the kept region is 320 px wide, upscaled back to 1920.

6. **Multi-clip (ramp-mode) sources**: `frameSourceTimes` is flattened across regions and indexed by `compositionTime × fps` in the crop pass. The warp path disables the `BurstRamp` stitch retime, so the map holds — but if `VideoBlender`'s VFR resilience emits more output frames than the schedule predicted, the index runs off the end of the rect array and the tail simply holds the last framing. It degrades gracefully; it is also completely untested.

### C3. The UX problems, ranked

**A. You are not framing the frame you think you are.** `WarpPreviewLoader` sets `requestedTimeToleranceBefore/After = .positiveInfinity` (`WarpTimelineView.swift:21-22`), so the still under the crop box is the *nearest keyframe* — potentially seconds away from the playhead. That is a defensible trade for a scrub thumbnail; it is the wrong foundation for a WYSIWYG framing tool. You compose a punch on a subject that is not where the render will find it. **This is the most damaging defect in the feature** and the fix is scoped: request exact frames (or a small tolerance) whenever the reframe lane is open.

**B. There is no way to see the move.** No play, no scrub-through-motion, no onion-skin or path ghost of the crop over time, no "preview the punch". The only way to see what you authored is to Create the clip — a full blend plus a full crop re-encode. For an animated-camera feature this is the highest iteration cost in the app, and it is why every other problem below is expensive: you find out at render time.

**C. Uncommitted framings die silently.** `AdjustView.swift:93` clears the draft on *any* playhead change. Dragging a lane diamond sets the playhead (`ReframeLaneView.swift:138`); tapping anywhere on the timeline bar scrubs. So a stray tap discards a framing you were shaping, with no confirmation, no toast, and no undo — drafts are view state and never reach the undo stack.

**D. The same gesture has two meanings 0.05 s apart.** On a key, pinch/drag mutate the key immediately (undoable, but destructive-by-default). Off a key, the identical gesture is non-committal and needs an explicit "Set keyframe". The only signal is a small badge: "K2 · 1.8× punch" vs "≈ between keys". Users will edit a key when they meant to explore, and explore when they meant to edit.

**E. Near-duplicate keys are easy to make.** To edit an existing key the playhead must be within 0.05 source seconds of it (`ReframeCanvasView.swift:57`). Tapping the diamond snaps there and works; tapping the *bar* next to it does not — you get a draft, then a second key a few frames away. There is no snap-to-nearest-key on the playhead and no "you are 0.3 s from K2" affordance.

**F. Five clocks on one screen, none of them labelled.** The key line says "Key 2 of 3 · **1:30**" (source), the move pill says "**~1s** ease" (output), the ruler is clip seconds, the preview badge is source clock, the estimate card is clip seconds, and the speed chips are ×-real-time. The only place that names its clock is the move popover hint ("…of viewer time"). For a feature whose whole subtlety is the source↔clip mapping, this is the core comprehension failure.

**G. The move control vanishes exactly where it matters.** Move pills are drawn only when the gap is wider than 58 pt (`ReframeLaneView.swift:162`). In fast stretches — where gaps collapse in output time and the move behaviour is most surprising — the pill disappears and there is **no other way to reach a move**: no list, no selection-line equivalent, no keyboard path.

**H. The Advanced ramp silently voids the whole track.** `reframeTrack` is nil'd when `compiledWarp()` is nil, i.e. whenever the Advanced ramp is on (`AppModel.swift:2311-2315`). Authoring keys turns the ramp off, so the collision only happens if the ramp is switched on *afterwards* — at which point the reframe row still reads "3 keys", the canvas still previews the punch, the CTA still says Create, and the only warning is a caption inside the speed-chips block, above the reframe row (`AdjustView.swift:420-423`). A render that discards an entire authored track deserves more than a caption.

**I. Changing the canvas silently re-frames every key.** Keys are stored as centre + zoom against a canvas aspect. `ReframeTrack.clamp(aspect:sourceSize:)` exists precisely to re-clamp them on a canvas change — and is **never called from anywhere** (no call sites in the tree). The crops are instead re-derived and re-clamped at evaluation, so a punch composed flush to a subject at 16:9 drifts when the user tries 9:16, with no notice, no toast, and no undo entry.

**J. 6× punch, no resolution guard.** `maxZoom = 6` is reachable in a single pinch. The badge appends "· 320px" when punched; nothing says what that means, nothing warns, and there is no soft limit at the point where the crop drops below the delivery resolution.

**K. Mouse-only Macs cannot punch.** The empty-state copy is "Full frame — pinch the preview to punch in". Trackpad pinch works; a mouse has no zoom path — no slider, no scroll-wheel handler, no keyboard nudge, no numeric entry. Drag-to-position works. Given the Mac is the import-first platform, this is a real hole.

**L. No numeric entry, no copy-framing, no key list.** Direct manipulation only. The commonest shape — punch in, **hold**, punch back out to the same wide — requires matching key 1 and key 3 by eye, and the mismatch is invisible until render. "Match previous key" / "hold this framing" / a key list with values would each remove a whole class of failure.

**M. Progress lies about what it is doing.** The reframe pass sets `processingPhase = .grading` (`AppModel.swift:2385`), so the Processing checklist reads *"Applying the colour grade…"* while it is cropping — in a screen whose §4.9 design principle is explicitly that phases are never inferred. `statusMessage` is set correctly ("Baking the punch-in reframe…"); the checklist just has no case for it.

**N. Nothing states the cost.** No indication anywhere that a reframe adds a second full export of the clip, or that it re-encodes what the blend just wrote.

### C4. The use-cases it should serve

Stated as product intent, because the code today has no written spec beyond its comments. Roughly in order of how well the current build serves them:

1. **Punch into a slow-motion moment in a ramp shoot** — stay wide through the 100× runs, punch into the ¼× moment where there is frame-for-frame detail, ease back out. *This is the case the arrive-anchored move and output-second spans were designed for, and it works.* The keys land in a slow stretch where source and clip time are close, so the move durations mean what they say.
2. **Fix the composition of a whole clip** — one static key at z≈1.3 to straighten a subject that sits off-centre. Works today (one key = one constant crop), but it is discoverable only by learning the keyframe model first; there is no "just crop this clip" affordance.
3. **Punch into the action in a hyperlapse** — wide establishing at 100×, punch 2× for the moment that matters, back out. *Currently the worst-served case*: the gaps collapse in output time (C2.2), the pills disappear (G), the moves clamp silently, and there is no motion preview to catch any of it.
4. **Aspect re-purposing** — deliver a 9:16 vertical from a 16:9 shoot, panning to keep the subject in the tall frame (feeding Collections and social). Needs reframe and canvas to cooperate; today the canvas is an unrelated header menu and switching it silently invalidates the framings (I).
5. **Subject tracking over a long timelapse** — sun, shadow, tide, a crane; a slow pan holds the subject as it crosses the frame over hours. The `thru` (linear) curve exists exactly for this. Needs many keys, and therefore needs the things that are missing: a key list, numeric entry, and a way to see the drift before rendering.
6. **Multi-crop deliverables from one shoot** — a 16:9 master plus a 1:1 and a 9:16 cut. Structurally possible (three blended clips), but each needs its own render and the keys do not survive a canvas switch coherently.
7. **Ken Burns on a stacked still or an interval shoot** — not supported (video only, by design). Worth recording as a deliberate non-goal or a future.

### C5. Suggested triage

| Tier | Items | Character |
|---|---|---|
| **Correctness / truth** | A (exact-frame preview when the lane is open), H (block or loudly warn on ramp + reframe), I (call `clamp` on canvas change, or state the consequence), M (a `.reframing` processing phase) | Small, contained, mostly a few lines each |
| **Comprehension** | F (label the clocks; say "≈ 0.3 s of clip" next to a key), G (reach moves without the pill), the move-clamp readout ("capped to 0.04 s" in the `BurstRamp` idiom) | Copy + small UI |
| **Iteration cost** | B (a motion preview of the crop path — even a stepped scrub or a path overlay), L (key list, numeric zoom, match-previous) | The real product work |
| **Ergonomics** | C/D/E (draft lifetime, gesture semantics, snap-to-key), J (resolution guard), K (Mac zoom path) | Design decisions needed |

---

## Part D — What to do with the document

1. **Rewrite §4.4** around Part B, and add a §4.4a for Punch-in reframe from Part C1–C2. This is the bulk of the work.
2. **Add the canvas** to §4.4 and `VideoCanvasCropper`/`ReframeVideoCropper` to the §3.1 diagram and §3.2 fork table (including the macOS "warped blends bypass the job runner" row).
3. **Delete or invert** §2.6's "No editing timeline required" bullet and §10's "no keyframe editing (deliberate)". Replace with the actual principle: *outcome first, mechanics on request — but the timeline is now the primary control for video.*
4. **Fix the contradictions**: §8's "collections … upcoming"; §10's "checklist stages are cosmetic".
5. **Extend §4.13's model list** with the five new `BlendProject` fields, and §9's hook table with the eight missing hooks.
6. **Update §10's test gaps** to name `WarpCompiler`, the reframe geometry, and `customWindows` — and consider that `WarpCompiler` and `ReframeMath` are pure functions with no dependencies, i.e. the two cheapest high-value tests available (the existing `WindowScheduleTests` is the template).
7. **Refresh the line counts** in §4.3, §4.10 and §9, or drop them in favour of "the largest file in `App/`".
8. **Add §7a's Vision path** and §4.9's branded loading states.
9. **Be precise about `docs/design/`** — `iOS/INDEX.md` is the current record for Adjust. Two of that card's five drawings are now current (§A3b); three are queued behind driven simulator gestures. Note that all five mirror the screen **as it ships today** — if the Part C fixes land, every one of them goes stale again, so the economical order is to settle the reframe UX first and redraw once.

# Capture Experience Investigation — Findings & Plan

**Against:** Camera Capture Experience Investigation Brief (2026-08-04)
**Scope:** Workstreams A–E, code-level investigation of `App/CameraController.swift`, `App/CaptureView.swift`, `App/LiveBlendController.swift`, `App/LiveBlendRawController.swift`, `App/CaptureBenchmark.swift`
**Status:** Findings + proposed plan. No code changed. Device-side confirmation steps are marked ⚠ where a claim needs a runtime log to be airtight.

The measurement harness from §2 of the brief is implemented at `tools/capture_metrics.py` (extract → intervals / preview-delta / chips / settle). It must first be validated against the reference recording to reproduce §3 — **the recording is not on this Mac**; drop it at `docs/capture-baseline/` (or any path) and run the commands in the file header.

---

## 1. Executive summary

1. **The lens model is hardcoded, but not the way the brief hypothesised.** The three chips map to three *discrete physical devices* (`.builtInUltraWideCamera` / `.builtInWideAngleCamera` / `.builtInTelephotoCamera`) and the app never touches `videoZoomFactor`, never uses a virtual device, and never uses `DiscoverySession`. So the "3×" chip **does engage the physical telephoto** — at the telephoto's *native* focal length. On the recorded device (native Camera offers 5×, so it has a 5× telephoto), the chip delivers **5× optics labelled "3×"**. The brief's §3.5 conclusion ("upscaled digital crop, telephoto never engaged") is contradicted by the code; the underlying finding stands in mutated form: the lens list and labels are constants, wrong on any device whose telephoto isn't 3×, and the discrete-device design forfeits everything the virtual device provides — smooth ramp, cross-lens AE handoff, the 2× sensor-crop stop, macro.
2. **Every switch is a full session teardown of the input.** `removeInput` → `addInput` → `commitConfiguration`, then a *second* reconfiguration re-pinning the format, then (in the recorded Photo + DNG scenario) a *third* one flipping the session preset back to `.photo`. Up to three live-stream restarts per tap, serialized on the session queue, with the preview layer showing the old device's live feed until the first commit lands. This is the 300–650 ms dead time, the hard cut, and (very likely) the 433 ms post-cut stall.
3. **The exposure jump is structural.** A brand-new `AVCaptureDeviceInput` per switch means AE/AWB/AF restart from scratch on the new device; nothing carries across. The native app's virtual device hands exposure across the switchover for free.
4. **The idle 24 fps preview is the armed-DNG configuration, not rendering.** The preview is a plain `AVCaptureVideoPreviewLayer` with zero app work per frame. But the recorded scenario (Photo mode, DNG armed) runs the session at preset `.photo` with **no frame-duration floor**, so auto-exposure's adaptive frame-rate sinks the sensor cadence (~1/24 s indoors → the measured 24.1 updates/s, 51.7 ms p95). Video/JPEG configurations pin min=max frame duration and should hold their rate — the recording never tested them. Prediction the harness can confirm: idle preview in Video mode at 30 fps will show ~0 jitter.
5. **The 134–150 ms selection-indicator limbo is UI-layer, deterministic, and cheap to fix** — consistent with the `.plain` ButtonStyle's *animated pressed-state fade*: on touch-up the old chip's amber unhighlights instantly while the new chip's amber fades up from the dimmed pressed appearance, sitting below the brief's HSV thresholds for ~150 ms. (Deterministic duration across all four measured switches is the tell — session work varies 300–433 ms, this never does.) Selection is also colour-only on a 1 pt stroke + 12 pt text — a small mask target.
6. **Adjacent correctness finding (new):** Photo-mode **JPEG** stills are captured at the *video* resolution ceiling — at the default 1080p format that is a **2 MP still**. Only DNG-armed capture uses the full 4:3 sensor. Details in §5.

Severity order for fixing: (1) lens model + labels [correctness], (2) switch mechanism [perceived quality], (3) chip repaint [trivial, do first], (4) preview floor [smoothness], (5) photo-JPEG resolution [correctness, adjacent].

---

## 2. Workstream A — lens/device model

### How the list is produced

- `CameraController.Lens` (`App/CameraController.swift:26–60`): a hardcoded 3-case enum, each case mapping to a device type. No runtime derivation of any kind.
- `publishAvailableLenses()` (`:773`) filters cases by `AVCaptureDevice.default(deviceType:for:position:) != nil` — presence-only. Labels are hardcoded in `CaptureView.swift:2541–2553`: `.5× / 1× / 3×`.
- `configureLens(_:)` (`:795`) resolves the case to a device and swaps the session input. **No `videoZoomFactor` is ever set anywhere in the app** (verified by repo-wide search; also no `DiscoverySession`, no `builtInDual*/Triple*` virtual types, no `ramp(toVideoZoomFactor:)`).

### What each chip actually delivers

| Chip | Device | Actual FOV |
|---|---|---|
| .5× | `builtInUltraWideCamera` | 0.5× (correct) |
| 1× | `builtInWideAngleCamera` | 1× (correct) |
| 3× | `builtInTelephotoCamera` | **The hardware telephoto's native FOV: 3× on iPhone 15 Pro-class, 5× on 15 Pro Max / 16 Pro / 17 Pro-class.** Label is wrong on 5× hardware. |

⚠ Device confirmation (one log line, part of Stage A): log `device.localizedName`, `activeFormat`, `videoZoomFactor` (should read 1.0), and the format's `fieldOfView` at each stop. The reference recording can also confirm it visually — the 1×→"3×" cut should show a ~5× FOV ratio between matching features, not ~3×.

### Consequences beyond the label

- **No 2× sensor-crop stop** (native offers it; it lives at `videoZoomFactor 2.0` on the wide, which the app cannot express).
- **No macro**: the ultra-wide's close-focus regime needs the virtual device's automatic switchover (or explicit handling); absent by construction.
- **No front camera**: not representable in the enum. Needs a product decision — for timelapse it's plausibly in scope (sunrise selfie-lapse), but it's a session topology change (position `.front`), i.e. the one case a zoom ramp can't cover.
- **Pinch is stepped, not continuous** (`CaptureView.swift:967–993`): each threshold crossing triggers a *full input-swap switch*; a fast pinch across the range queues two heavyweight reconfigurations back-to-back on the session queue.
- **Device classes**: on single-rear-camera devices (and the Mac, which uses `AVCaptureDevice.default(for: .video)`), `availableLenses` collapses to `[.wide]` and the chips hide (`CaptureView.swift:1572`). iPads lose the missing tele/UW correctly. So availability *degrades* correctly — only the labels and the missing stops are wrong.
- The Watch never switches lenses (no `selectLens` callers outside `CaptureView`), so the lens model rework does not touch the Watch protocol.

### What Workstream A should build (proposal)

Replace the enum with a runtime-derived model:

1. Pick the capture device per position: `AVCaptureDevice.DiscoverySession` preferring `.builtInTripleCamera` → `.builtInDualWideCamera` → `.builtInDualCamera` → `.builtInWideAngleCamera` (first match wins).
2. Read `virtualDeviceSwitchOverVideoZoomFactors` + `constituentDevices` to derive the true optical stops; label each stop from the actual factor (0.5 / 1 / 5 …), formatted from hardware, not constants.
3. Represent computational stops (2× crop; any future 10×) explicitly in the model with an `isComputational` flag → visually badged (Indigo's "SR" pattern). **Needs a design decision from Steven on the badge treatment** → design-sync: the capture-screen SVGs must gain the derived-chips + badge spec before implementation (per `docs/design/README.md` contract).
4. Selection becomes `setVideoZoomFactor` (snap) / `ramp(toVideoZoomFactor:rate:)` (animated) on the *one* virtual device input — no input swap, no format re-negotiation, no preset flip.
5. Keep the discrete-device path behind a fallback for: macOS (single device), devices without a virtual rear camera, and — pending the ⚠ probe below — the Bayer-RAW pipeline.

**~~The one open risk~~ — resolved on hardware (2026-08-04).** The Capture optics probe run on the iPhone 16 Pro shows `availableRawPhotoPixelFormatTypes` **empty at every stop on the virtual Triple Camera**, while the iPad's physical wide device offers `rgg4` (`docs/capture-baseline/optics/`). Plain Bayer RAW is a physical-device capability: **DNG-armed capture keeps a discrete-device session** (with the Stage-3 single-transaction fallback + freeze cover for its switches, optical stops only), while every other mode moves to the virtual device and the ramp. Single-camera devices (iPads) are unaffected. ProRAW on virtual devices exists but is a demosaiced pipeline — not a substitute for the Bayer mosaic blending in §6 of the app overview.

---

## 3. Workstream B — switch transition

### Where the dead time goes (code-level breakdown)

`selectLens` (`CameraController.swift:782–793`) runs this sequence on the session queue; in the recorded scenario (Photo mode, DNG armed → session preset `.photo`):

| Step | Work | Est. cost class |
|---|---|---|
| 1 | `AVCaptureDeviceInput(device:)` for the new lens — powers up the camera module | ~50–150 ms |
| 2 | `beginConfiguration` → `removeInput(old)` → `addInput(new)` → `commitConfiguration` | **live-stream restart #1** — the visible hard cut; until it lands the preview shows the *old* device's live feed |
| 3 | `refreshCaptureOptions()` → enumerates every format × frame-rate range, then `applyCaptureFormat` sets `activeFormat` + min/max frame durations + `photoOutput.maxPhotoDimensions` | **live-stream restart #2** (setting `activeFormat` restarts the stream) — and it pins the 16:9 *video* format even though DNG framing is armed |
| 4 | `publishLiveBlendDNGSupport` → `probeBayerRAW` (`:619`): on the **first** switch to each device per screen-open, flips `sessionPreset` to `.photo` and back — **two more begin/commit cycles** — then recursively re-applies the capture format | first-visit only (cache is per-`CameraController`, i.e. per screen-open) |
| 5 | `reassertPhotoAspectPreviewIfArmed` (`:722`) → `applyPhotoAspectConfiguration`: `sessionPreset = .photo` again | **live-stream restart #3** — and the likely owner of the 433 ms stall *after* the hard cut (the stall sits ~420 ms after the FOV change at 26.822 s → 27.24 s) |
| 6 | AE/AWB/AF start from zero on the new device | the ~300–500 ms exposure convergence in §3.3 of the brief |

Steps 2/3/5 are three separate session transactions where one (or zero, post-A) is needed. Step 3 also explains a subtle artefact: mid-switch the sensor is briefly on a 16:9 video format between two 4:3 photo configurations.

⚠ To confirm the exact split on device, Stage 0 lands `os_signpost` intervals around each step (the `LLog` timestamps already bracket most of them) and one Instruments run on the phone reproduces the brief's switch cycle. The harness then measures the screen side of the same events.

### The selection-indicator limbo (§3.4 of the brief)

`zoomChips` (`CaptureView.swift:1579–1601`): selection is **optimistically updated on the main thread at tap time** (`camera.selectedLens = lens` before the async `selectLens`), so the limbo is *not* session latency. There is also no explicit animation in the chip code. The leading explanation is the `.plain` ButtonStyle's animated pressed-state fade: the action fires on touch-up while the pressed dim is still applied to the tapped chip, the old chip snaps to unselected in the same render, and the new chip's amber then *fades up* through the ~150 ms system fade — below the brief's S/V mask thresholds until late in the fade. The deterministic 134–150 ms across all four switches (while everything session-side varies) fits an animation constant and nothing else found in the code.

Fix (trivial, measurable): custom `ButtonStyle` with instant pressed/selected rendering, and make selection a *filled* chip (bigger mask area, no colour-only 1 pt stroke). Verify with `capture_metrics.py chips` — target ≤ 35 ms, never zero-selection.

Adjacent hygiene: the chips are `.disabled`/hidden while capturing, but the optimistic write pattern (`selectedLens = lens` + a `selectLens` that can silently refuse via its guard, `CameraController.swift:784`) can desynchronise highlight from reality in race windows (tap landing as a run starts). Post-A this collapses: selection = zoom factor, applied unconditionally-cheaply.

### Ramp vs dissolve — decision: **ramp** (confirmed by Steven, 2026-08-04)

- **Ramp (native pattern)** is the primary mechanism, and it falls out of Workstream A rather than being extra work: with one virtual-device input, a "switch" is `ramp(toVideoZoomFactor:)` through the stop — the system crosses constituents itself, carries AE/AWB across, every intermediate frame is live imagery, and there is *zero* session reconfiguration to hide. The dead time isn't masked; it's gone. It also matches the user's native-camera muscle memory, gives continuous pinch zoom for free, and makes mid-recording zoom possible later (Workstream D).
- **Dissolve (Indigo pattern)** is the cover for transitions that genuinely change session topology, where a ramp is impossible: the DNG-armed preset change (if the RAW probe forces DNG onto a discrete-device session), a future front↔back flip, and cold-start/resume blanking (Workstream E). Implementation: freeze the last preview frame (snapshot overlay), dip/cross-fade, remove on the first post-reconfigure frame *after AE has a couple of frames to bite* — never show the old lens's live feed after a tap, never show the raw under-exposed first frames.
- **Do not** build dissolve as the primary switch mechanism: it spends effort hiding a cost that Workstream A deletes, and it can't meet "tap → new FOV ≤ 250 ms" if three stream restarts remain underneath it.

Interim option if A's device work slips: batch steps 2/3/5 into **one** `beginConfiguration`/`commitConfiguration` transaction (input swap + format + preset in a single commit — AVFoundation supports this) and skip `applyCaptureFormat`'s video-format pin when DNG framing is armed. That alone should roughly third the dead time and remove the post-cut stall; it's also the right shape for whatever remains on the discrete-device fallback path.

Exposure continuity on the fallback path: seed the new device from the old device's `exposureDuration`/`iso`/white-balance gains via `setExposureModeCustom` for the first ~0.5 s, then release to continuous auto — the same trick `reassertExposureLock` already plays for locked exposure (`:1022`).

---

## 4. Workstream C — preview frame rate and hitching

### What's ruled out

- **Rendering path**: `CameraPreview` is a plain `AVCaptureVideoPreviewLayer` bound to the session (`CaptureView.swift:2928–3070`); no sample-buffer tap feeds the preview, no Core Image, no per-frame main-thread work. `updateUIView` only pokes `videoGravity`/orientation on state changes.
- **Per-frame app work at idle**: the only `AVCaptureVideoDataOutput` (`liveBlendOutput`) is attached lazily on the first JPEG-blend run and its delegate is detached between runs (`CameraController.swift:2075–2087, 2145`). In the recorded session (Blend off) it plausibly never attached at all. The 0.5 s UI tick (`CaptureView.swift:138`) re-evaluates the body twice a second — noise, not a 40 % frame tax.

### The likely root cause in the recorded scenario

Photo mode + DNG armed ⇒ `setPhotoAspectPreview(true)` ⇒ `sessionPreset = .photo` (`CameraController.swift:685–717`). In that configuration **nothing pins frame durations** (`applyCaptureFormat` is video-path-only and explicitly skipped while armed, `:639`), so the device runs the photo format's default adaptive AE range: in indoor light AE extends shutter toward 1/24 s and preview cadence follows. That reproduces the observed 24.1 updates/s with a 33.3 ms p50 and ~50 ms excursions — *without any app-side frame dropping*. Native Camera holds ~30 in the same room because it manages its preview cadence and spends the light on ISO instead.

Fix candidate: in the photo/DNG configuration, set `activeVideoMaxFrameDuration = 1/24`–`1/30` (floor the cadence) and let AE spend on ISO — matching reference behaviour. Trade-off to state honestly: bounding the streaming AE also bounds still exposure for RAW captures in very low light (night interval shoots). Proposal: floor at 30 fps to match native; if night-lapse regressions appear, relax the floor only below a lux threshold (or expose it under Advanced).

⚠ Device verification + harness prediction: idle preview in **Video mode** (min=max pinned at the selected rate, `:989–991`) should already hold a rock-steady 30 fps; idle in **Photo+DNG** shows the sag. If a re-measurement shows Video-mode idle *also* jittering, the next suspect is thermal/system pressure, and `AVCaptureSessionWasInterrupted`'s system-pressure reason plus `AVCaptureDevice.systemPressureState` logging (Stage 0) will catch it.

### Also noted

- **The min=max pin couples preview rate to acquisition rate.** Selecting a 10/12/15 fps interval acquisition rate previews at 10–15 fps. If that's not intended UX, pin only `activeVideoMinFrameDuration` for capture pacing and leave preview max at 30 — needs a deliberate decision because for *video recording* the coupling is physically required.
- **Screen-updates vs preview-updates**: part of the brief's "35.3 vs 60.7 screen updates/s" gap is a measurement artefact of LetsLapse's mostly-static chrome — a static UI over a 30 fps preview *cannot* exceed ~30–35 stored frames/s in a VFR screen recording. The meaningful comparisons are the live-preview crop rate (24.1 vs 30.2) and the stall table, both real. Recommend re-basing the §5 "steady-state p95 ≤ 20 ms" target on the *preview-crop* series (≤ 35 ms p95 at 30 fps; ≤ 20 ms only if we adopt a 60 fps preview format where hardware allows).
- **Frame-drop telemetry** the brief asks for: `LiveBlendController` already counts camera drops (`didDrop`, `LiveBlendController.swift:434`) but ignores the reason. Add `kCMSampleBufferAttachmentKey_DroppedFrameReason` readout to the drop handler and to a DEBUG-only tap during measurement runs.
- The stalls > 100 ms in §3.2 cluster at switches — same root cause as §3 (session transactions), not the idle jitter. Fixing B is expected to zero this row; the harness verifies.

---

## 5. Workstream D — mode × format × lens matrix

Session configuration per mode (all from `CameraController` / `CaptureView` as of this commit):

| Mode · format | Engine / outputs | Session config | Lens chips | Notes |
|---|---|---|---|---|
| Photo · JPEG | `photoOutput` burst via interval timer + frameCap, auto-stacked | preset `.high`, pinned 16:9 video format, min=max fps | .5 / 1 / tele | **Stills capped at ≤ the *video* resolution** — `bestPhotoDimensions` filters to `≤ resolution.pixelCount` (`CameraController.swift:1098–1112`): at 1080p that is a 2 MP still. Semi-pro Photo mode should shoot the sensor's max regardless of the video dial. |
| Photo · DNG | `LiveBlendRawController`, RAW captures → blended/pass-through DNG | preset `.photo` (armed via `setPhotoAspectPreview`), full 4:3 sensor | .5 / 1 / tele, gated per-device by Bayer-RAW probe | Blend Off writes the single RAW untouched. ⚠ Confirm probe passes on UW + tele on the target device (expected yes on Pro rear lenses; the armed preview disarms honestly if not, `:722`). |
| Interval · JPEG, Blend Off | `photoOutput` timer (`frame-%05d.jpg`) | pinned video format | .5 / 1 / tele | Same ≤ video resolution cap as Photo·JPEG. |
| Interval · JPEG, Blend on | `LiveBlendController` video-tap (adds `AVCaptureVideoDataOutput`) | pinned video format | .5 / 1 / tele | Output = video-format frames (e.g. 1080p/4K JPEG). Backpressured, drop-counted. |
| Interval · DNG (any blend) | `LiveBlendRawController` | preset `.photo` for the run, restored after | gated by RAW probe | iOS/iPadOS only; macOS has no RAW API. |
| Video · H.264/HEVC `.mov` | `movieOutput`, system codec defaults | pinned video format at selected fps (up to 240) | .5 / 1 / tele | Per-lens format lists differ (UW/tele lose high-fps and some resolutions) — already probed per device, so the pickers adapt. |
| Video · ProRes | `movieOutput`; ProRes arises when the active format is a ProRes format (FourCC-detected, `:223`) | pinned ProRes format | whichever lenses offer ProRes formats | ⚠ Report per-lens ProRes availability from the device probe (expect wide always; UW/tele limited by model). |
| Any mode, macOS | — | single `AVCaptureDevice.default(for:.video)` | chips hidden (1 device) | No RAW, no tele/UW — degrades correctly. |

**Lens switching mid-run — every mode:** blocked. `selectLens`/`selectResolution`/`selectFrameRate` all guard on `!isRecording && intervalTimer == nil && !isLiveBlendActive` and **silently no-op** (`CameraController.swift:784`); the UI hides the chips while capturing (landscape, `CaptureView.swift:792`) or shows them disabled (portrait Photo-burst, `:744`), and the pinch gesture checks `isCapturing`. So: a mid-sequence switch is *not possible today* — no dropped frame, no glitch, simply refused. That is a defensible policy for Interval (frame geometry must not change mid-stack — the blend pipeline's size guard would reject it), but it should become an *explicit, documented* policy with UI affordance (dimmed chips + a hint) rather than a silent guard, and the controller should report refusal rather than letting the optimistic UI write drift.

**Video mid-recording:** also refused. Structurally, `AVCaptureMovieFileOutput` cannot span an input swap mid-file, so the discrete-device design cannot ever match native's mid-recording lens change. Post-A, a `videoZoomFactor` ramp during recording works with the movie output (this is how native does it) — including under ProRes, subject to the format staying fixed (the ramp never changes format). Ship as a policy decision in D: allow zoom ramp mid-recording in Video mode; keep Interval locked.

**Interval timing vs preview load:** the interval timer is a `DispatchSourceTimer` on the session queue (`:1866`) — no main-thread coupling, and switches are blocked mid-run, so nothing in Workstreams B/C can stretch tick spacing. Shot-to-shot latency variance comes from the photo pipeline itself (already characterised in `CaptureBenchmark.swift`). ⚠ Confirm with capture timestamps over a 100-frame run while scrolling/animating the UI.

---

## 6. Workstream E — cold start and resume

- **A fresh `CameraController` per capture-screen presentation** (`@StateObject` at `CaptureView.swift:25`): every open pays full session configuration — including `probeBayerRAW`'s two preset flips (the probe cache dies with the controller) — before `startRunning()`. Create is the launch tab and auto-presents the camera, so this is the app's cold-start path too.
- **Sequencing**: `start()` → `requestAccess` callback → configure (with probe) → `startRunning()` (blocking, typically 100–300 ms) — then, for Photo/Interval+DNG, `updateAspectPreview()` flips the running session to `.photo` *after* startup → a visible 16:9→4:3 letterbox snap late in the launch.
- Recommendations for E (after A–C land): hoist the controller to an app-scoped object that survives screen closes (`stop()` already keeps configuration; reopening then costs only `startRunning`); persist the RAW-probe result per device across launches; arm the photo-aspect preset *inside* the initial configuration transaction when the remembered mode wants it (no post-start flip); cover the remaining gap with the Stage-B freeze/dissolve instead of showing a stale or black frame. Resume is already handled (`resumeIfNeeded` on interruption-end / foreground) — measure it, and verify the preview layer never shows a stale frame post-resume (freeze-frame cover applies).
- ⚠ Measure with the harness: cold launch → first live preview frame; background → resume → first live frame. Baseline targets: Indigo does 1.6 s cold including splash.

---

## 7. Acceptance criteria — mapping and two renegotiations

| §5 target | Owned by | Note |
|---|---|---|
| Indicator repaint ≤ 35 ms, never none | Stage 1 (chips) | Fix is UI-only; measure with `chips` subcommand |
| Tap → new FOV ≤ 250 ms | Stage 3 (ramp) | Ramp makes this ~0 ms to *start* moving; "new FOV visible" becomes ramp completion |
| Tap → settled ≤ 500 ms | Stage 3 | Virtual device carries AE across; fallback path seeds exposure |
| Peak switch delta ≤ 40 | Stage 3 | Ramp = continuous imagery; dissolve covers topology changes |
| 0 intervals > 33 ms during switch | Stage 3 | Follows from no session transaction on switch |
| 0 intervals > 100 ms anywhere | Stages 3+4 | Cold-start/resume covered by Stage 6 |
| Steady p95 ≤ 20 ms | Stage 4 | **Renegotiate**: static chrome over a 30 fps preview cannot store >~35 fps in a VFR recording; propose preview-crop p95 ≤ 35 ms @30 fps (≤ 20 ms only if a 60 fps preview format is adopted) |
| Preview ≥ 30 updates/s | Stage 4 | Frame-duration floor in photo config |
| Chips match optics, computational badged | Stage 2 | **Correct the premise**: today's tele chip *is* optical (mislabelled); the criterion becomes "labels derived from hardware, every optical stop listed, computational stops badged" |

---

## 8. Proposed implementation plan (sequenced)

Numbered stages = separate PR-sized units, each ending with a harness re-measurement against §5 and (where UI changed) the SVG mirror per the design-sync contract.

- **Stage 0 — instrument + validate the harness (no behaviour change).** `os_signpost` intervals around input creation, each begin/commit, `activeFormat` set, preset changes, and first-frame arrival; add drop-reason readout to `LiveBlendController.didDrop`. Validate `tools/capture_metrics.py` against the reference recording, reproducing §3 (needs the recording file). One Instruments run on device to get the real B-breakdown.
- **Stage 1 — chip repaint (§3.4).** Custom ButtonStyle, instant selected state, filled selection chip. Cheapest visible win; also removes the optimistic-write drift by moving selection publication into the controller's confirm path (or making refusal impossible post-Stage-3). *SVG mirror: capture screens' chip treatment.*
- **Stage 2 — runtime lens model (A).** Now specified in `capture-optics-spec.md` (decisions locked 2026-08-04: native stops always, 2× computational stops on by default, Settings → Capture Optics, sensor crops preferred over digital upscale). Groundwork shipped: the derivation rule + on-device diagnostics live in `App/CaptureOpticsProbe.swift` (Settings → Advanced → Capture optics probe) — run on each device to validate the rule and the Bayer-RAW-on-virtual question before the design files. *SVG mirror: chip sets per device family + badge (design stage, after probe results).*
- **Stage 3 — switch transition (B).** *Core landed 2026-08-04 together with Stage 2* (Steven: skip SVGs for now, test on device): standard-world selection is a zoom ramp on the virtual device (no session transaction; `applyCaptureFormat` re-asserts zoom after format changes), and Stage 1's chip repaint fix (`ZoomChipButtonStyle`) landed with it. Landed later the same day after device testing confirmed JPEG/Video "great" but DNG "horrible": DNG-world switches collapsed to ONE session transaction (input swap only — no video-format pin, no preset flip; the armed world stays in the photo configuration) under a dip cover (`isSwitchingLens` → viewfinder dips ~0.16 s, holds 0.35 s over the reconnection + fresh AE), also wrapping arm/disarm. Still open: continuous pinch (currently stepped, each step ramping), auto-exposure seeding across DNG swaps (lock already re-asserts), the cold-start cover, and re-measurement.
- **Stage 4 — preview cadence (C).** Frame-duration floor in the photo/DNG configuration; decide min-only vs min=max pinning for low interval acquisition rates; re-measure idle in all three modes.
- **Stage 5 — mode × format verification (D).** Run the matrix on device (per-lens RAW + ProRes availability), land the explicit mid-run lens policy (documented + affordance), decide mid-recording zoom for Video, and fix the **Photo/Interval-JPEG resolution cap** (decouple still dimensions from the video resolution dial — likely its own small brief since it touches the format sheet UX). *SVG mirror where the format sheet changes.*
- **Stage 6 — cold start/resume (E).** App-scoped controller lifetime, persisted probe cache, armed-preset in the initial transaction, dissolve cover on start/resume; measure against Indigo's 1.6 s.

Re-measurement protocol after every stage: §2 procedure on the same device class, all three modes — `intervals` (idle + switch segments), `preview-delta` (switch peaks), `chips` (repaint), `settle` (convergence), against the §5 table (as amended in §7).

---

## 9. Open questions — status 2026-08-04

1. ~~Capture optics policy~~ **Resolved**: native stops always + derived 2× computational stops on by default, Settings → Capture Optics to hide, groundwork-first sequencing. Full spec: `capture-optics-spec.md`. Badge *visual treatment* lands with the design files (chips must distinguish optical / sensor-crop / digital).
2. **Front camera and macro** — still open; out of scope for the Capture Optics groundwork (front = new session topology; macro can ride the virtual device later).
3. **Mid-recording zoom in Video mode** (post-Stage-3 capability): still open; decide once the ramp exists.
4. **Low-light trade-off of the preview floor** (Stage 4): still open; recommendation stands (30 fps floor, night relaxation only if interval night shoots regress).
5. **Photo-JPEG resolution cap** (§5 finding): still open — fold into Stage 5 or split out.
6. ~~Reference recording~~ **Resolved**: Steven records fresh baselines on request (iPad Air M1, iPad Air M3, iPhone 16 Pro available; the 16 Pro is the primary dev device). A new §2-procedure recording from the 16 Pro validates the harness for Stage 0; probe reports from all three devices validate the optics derivation.

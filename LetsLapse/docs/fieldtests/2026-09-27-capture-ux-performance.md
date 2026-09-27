# 2026-09-27 — Capture UX and performance: audit, baseline, fixes

Steven's report (15:23, iPhone 18 Pro; 15:44 and 16:21, iPhone 16 Pro): Settings
"jumpy" on a quick scroll; a photo makes "nasty redraws", the layout "jumps
around"; tap-to-focus "feels buggy, like the click is known but not accepted";
the focus square "gone in an instant, like something is fighting it"; against
the iOS Camera app the capture "just looks so unprofessional". The plan that
governs the measurements is `docs/performance-baseline-plan.md`; the hands-free
harness is `tools/perf_baseline.py`; the traces are in `docs/traces/`
(git-ignored); the walk's two-way log is `docs/dispatch/2026-09-27-capture-ux.md`.

## 1. Findings

Everything below was measured, not guessed: Instruments traces (Time Profiler
+ Hangs, App Launch) over USB, the app's own signposts and console log, and
frame-by-frame reads of the three screen recordings (a 60 fps recording emits
a new frame only when the display changes, so a frozen display shows up as
missing frames and a jump as one frame with a large delta).

### 1.1 A photo costs 2.4 s, and the app spends most of it swapping lenses

The one-lens-per-shoot rule (morning of the 27th) was applied **per shot** in
Photo mode. On every press the run pinned the stop's physical lens:

| Phase (cool 18 Pro, 1×, same lens as the last shot) | Time |
|---|---|
| press → session queue | 0 ms |
| `lens pin`: input swap, combined camera → physical lens | 0.28–0.35 s, **viewfinder blacks out** |
| `AE settle`: the swapped-in lens's exposure from scratch | 0.56–1.17 s, every shot |
| press → fire | 1.29–1.41 s |
| `lens pin release`: swap back | 0.53–0.62 s, **second blackout** (a wrong-exposure flash on the 16 Pro) |
| run flag off (chrome returns) | 2.27–2.40 s |
| press → recorded | 2.34–2.45 s |
| main-thread CPU in that window | 107–150 ms |

A lens change added 0.67–0.70 s + 0.17 s of `applyCaptureFormat` and a longer
AE settle (press → fire 1.8 s). Thermal state made no difference to these
numbers (the 15:23 shots at `serious` and the 16:16 shots at `nominal` agree).
The iOS Camera keeps its preview and its exposure across a shot because it
never leaves the combined camera.

### 1.2 The chrome collapses three times per photo

From the recordings: the press → the bottom chrome (mode row, lens chips,
BLEND row, banner, the four cluster slots) collapses to a lone stop square
1.2–1.3 s later (when `isIntervalRunning` finally flips) → 1 s later it comes
back with a "1/1" progress row that shifts the layout → 1.5 s later the row
goes and BLEND returns. Cause: `clusterSlot` emptied its slots for any
`isCapturing`, `photoControlsRow` and `modeRow` hid for it, and the burst pill
replaced the dial row even for a single still.

### 1.3 The focus square dies after 120 ms

`applyTapFocus` waits 0.12 s for a hunt to begin; a lens that is already in
focus never starts one, so the tap was judged "no hunt began", the pin dropped,
and `isFocusPinnedByTap` → false removed the reticle. The same removal ran
after every photo (`releaseRunFocusLock`). The tap set no exposure point, so
nothing visible answered it either.

### 1.4 Every photo triggers a whole-library pass on the main thread

Hang attribution (`perf_baseline.py hangs`): after each of the ten remote
shots, a 0.47–0.63 s main-thread hang running `PicPlaceController.updateTally()`
→ `LibraryIndex.projectID(originID:)` + `CaptureProject.init(from:)` for all
1,335 projects. It runs after every PicPlace usage refresh, which follows every
records push, which follows every new photo.

### 1.5 Settings: ten seconds of main-thread hangs in the first fourteen

B-hook on the 18 Pro (`LL_TAB=settings` from launch): 13 hangs between 3.5 s
and 14 s totalling ≈10 s, all whole-library passes decoding every project's
document on main: `disconnectSummary()` (from the PicPlace card's body),
`updateTally()`, `SettingsView.librariesCardPhone`, `AppModel.source(for:)` /
`posterURL(for:)`, the free-up estimate (candidates 0.34–0.40 s and judge
0.55–0.93 s on main; listings 2.2–4.8 s off main) and `LibraryIndex.upsertAssets`
from the PicPlace check. The 15:23 recording's scroll shows exactly two
freezes (0.9 s, 0.85 s) around one moving frame — the estimate's two
main-thread phases with the off-main listing between them. On the 16 Pro the
list did not move for ≈6 s after the tap.

### 1.6 Launch

First frame at 1.0 s (App Launch template). Then, on the persister's queue,
the walk (1.33–1.70 s on the 18 Pro, 2.2–2.9 s on the 16 Pro) and the export
regenerated **every** launch (0.7–1.8 s) because six blends are in the
documents and not in the index; on the main thread, 3–4 hangs of 0.36–0.93 s
in the first six seconds (`updateTally`, the `source(for:)` pass) and one of
0.6 s at +21 s (`scheduleAssetBackfill` collecting every project's asset names
on main). The launch animation covers the first 3 s; the Create tab is
interactive at ≈5.5 s.

### 1.7 Smaller things seen on the way

- The Photo viewfinder ran at 30 fps (`photo viewfinder: 30.0 fps`); the iOS
  Camera previews at 60 on these displays.
- `watch-link updateApplicationContext failed … Device is not paired` is logged
  ~20 times a session on a phone with no Watch — noise, and a WCSession call
  each time.
- The 16 Pro's tele joined the session on 1920×1080 and needed two format
  applies (0.44 + 0.16 s) before its still; the 18 Pro's lenses joined on
  4032×3024 directly.
- Both phones reach `thermal: serious` within minutes of the capture screen
  running on USB; the app now logs the state at launch and on change.

## 2. What changed (this branch)

1. **Photo shoots from the combined camera** it is previewing on, with
   constituent switching locked for the run (`CameraController.startInterval`,
   `photoRunStaysOnOptics`): no input swaps, no exposure re-settle, no
   blackouts. The pin stays for a size only that lens has and for every
   Interval and blend run (the morning's rule, kept where it protects a shoot).
2. **A single still takes no focus pin** — a hunt in flight is allowed to
   land, then the frame is taken; nothing is locked and released around one
   frame.
3. **The chrome stays put through a shot.** Cluster slots, the mode row and
   the BLEND row remain (inert while the run lasts); a single still keeps the
   idle disc, which **dips at the press** while the viewfinder **blinks**
   (`acknowledgePhotoPress`); the progress pill mounts only for a burst or a
   Bulb window. Design mirror: `docs/design/components/shutter-cluster.photo-burst.portrait.svg`,
   `capture-photo.burst.portrait.svg`, index row updated.
4. **The focus square stays** until the next tap, a lens change, a mode change
   or the user's own unlock — not until the lens gives up a pin. **The tap also
   meters** where it points in Photo mode (unless exposure is locked).
5. **The Photo viewfinder asks for 60 fps**; the format clamps it.
6. **Library passes off the main thread** (`App/LibraryPass.swift`): one
   detached pass reads every project's facts (origin id, sources missing,
   poster, last edit) through the document store's own lock and a
   `peekDocument` that does not churn the LRU; `updateTally()` runs on it,
   coalesced to one pass per second; `disconnectSummary()` is computed only
   when the Disconnect button is pressed; the free-up estimate's candidates and
   judge run off main and the result is cached by (index, files, records)
   revision; the PicPlace check's merge loop, the asset backfill and the
   libraries card read their facts from the pass; the originals/blends queues
   yield every 32 rows.
7. **The export rebuilt every launch** — root cause: keep-both forks copied the
   origin's blend records with the same ids, and the index keyed blends by id
   alone with `INSERT OR REPLACE`, so a blend two documents named had one row
   that moved to whichever was written last and was then deleted by the
   other's purge; the export counted every document's entries, the index had
   lost rows, and the launch regenerated the export forever. Fix: index schema
   4 keys blends per document (rebuilt once on first launch), forks are
   re-keyed, `regenerateExport` reconciles first and the launch log names any
   blend the index lacks (`library: N blend(s) in the documents but not the
   index: …`); six Kit tests cover it.
8. **Instrumentation**: signposts for every phase above, `thermal:` in the log,
   `shutter: press` in the log, a hands-free harness (`tools/perf_baseline.py`)
   with A/B/C scenarios, log-only variants, `parse` and `hangs`.

## 3. Numbers

### iPhone 18 Pro — before (3eaad79), cool

See `docs/performance-baseline-plan.md` §5 for the full table. The headline:
press → recorded 2.4 s; press → fire 1.3 s; two blackouts; chrome collapse at
1.3 s; a 0.5 s main-thread hang after each shot; Settings 10 s of hangs in
14 s; launch first frame 1.0 s, interactive ≈5.5 s.

### iPhone 16 Pro — before (485fcd9 = 3eaad79 + harness), cool → fair

| Metric | Value |
|---|---|
| Settings from launch: hangs 4.7–18.3 s | 20 hangs, 13.6 s together (`disconnectSummary`, `source(for:)`/`posterURL`, `updateTally`, libraries card) |
| library walk | 1.87 s (log) / 3.3 s on the queue (signpost) |
| free-up estimate: candidates / listings / judge | 0.49 s main / 4.37 s off main / 0.61 s main |
| photo, same lens: pin → fire / fire → recorded | 0.15–0.47 s / 1.05–1.53 s (median 1.41 s) |
| photo, after a lens change: pin → fire | 1.13–1.49 s |
| photo: pin → recorded | median 1.62 s, 1.49–2.87 s |

The 16 Pro settles the swapped-in lens's exposure faster than the 18 Pro
(0.15–0.5 s against ~1 s), and takes longer from fire to recorded (1.4 s
against 1.0 s).

### iPhone 16 Pro — after the Photo change (WP1), serious

| Metric | Before | After |
|---|---|---|
| press → fire, 1× and 0.5× (same lens) | 0.15–0.47 s | **0.00–0.01 s** |
| fire → recorded | 1.05–1.55 s | **0.58–0.70 s** |
| press → recorded, 1× and 0.5× | 1.5–1.8 s | **0.58–0.71 s** |
| lens swaps per shot | 2 (both blackouts) | **0** — switching locked 0.55 s, restored |
| press → fire at 5× | 0.35–1.49 s | 2.0 s ✗ — the exposure-settle wait ran its whole 2 s budget on the combined camera's tele (`AE/AWB still settling`); a single still's wait is now capped at 0.35 s and re-measured below |
| launch (unchanged by WP1) | walk 2.0–2.2 s, export 1.75 s | same |

### iPhone 16 Pro — capped wait (f8284f4) and the merged build (908a2d1), serious → critical

| Metric | Before | Merged build |
|---|---|---|
| press → fire, 1× / 0.5× / 5× | 0.15–0.47 s / 0.15–0.47 s / 0.35–1.49 s | **0.00–0.01 s / 0.00–0.01 s / 0.37 s** |
| press → recorded, 1× / 0.5× / 5× | 1.6–1.8 s / 1.5–2.7 s / 1.5–2.9 s | **0.59–0.67 s / 0.79–0.89 s / 0.95–1.0 s** |
| of which the camera / registration | — | 0.41–0.45 s / 0.18–0.22 s (`capture: still delivered`) |
| lens swaps per shot | 2 | 0 |
| main-thread pass after each shot (`updateTally`) | 0.5 s hang on main | `picplace tally: … 0.5–0.6 s off main` |
| launch: export regenerated | every launch, 1.8–1.9 s | once after the index rebuild, then never (`library.json` counts agree) |
| launch: index rebuild (schema 4) | — | 18.3 s, once, on the first launch of the build |
| launch: PicPlace check's merge loop | on main (the 0.9 s hang) | `picplace check pass: … read in 0.6–2.0 s off main` |
| Settings from launch: hangs | 20 hangs, 13.6 s (nominal) | **5 hangs, 2.7 s** (at thermal critical); main busy in the 3 s after Settings appears 2.6 s → **0.59 s**; the free-up estimate entirely off main |
| the five that remain | — | four busy ones are `LibraryIndex.projectID(originID:)` under `PicPlaceController.refreshUsage` — one index query per server row on main; moved off main in b9fbc6e |
| **b9fbc6e, nominal: Settings hangs / main busy in the 3 s after appear / busy 0–10 s** | 20, 13.6 s / 2.6 s / 8.6 s | **1, 0.44 s / 0.23 s / 1.6 s** |

The last four remote shots of the merged run were refused at thermal
critical (`capture: refused to start at thermal critical — the lens stabiliser
parks there`): the phone had run its camera on USB for most of the day. The
refusal is by design and the 5× figures are the capped-wait run's.

### Simulator (iPhone 16 Pro, 164 projects, no PicPlace, no camera)

Walk 0.08 s, no export rebuild, no PicPlace check, Settings appears at 1.16 s
with 264 ms of main-thread work in the next 3 s and no hangs. The simulator
does not reproduce the phones' problems: they are the library's size and
PicPlace's bookkeeping, and the camera pipeline.

## 4. Tests

- `tools/perf_baseline.py --device "<name>" A|B|C|A-log|C-log|logs|library|install|parse|hangs|park`
  — the repeatable runs; §2 of the plan lists the conditions to pin.
- `shoot.py audit --device <alias>` after any capture change: `checkDeliveredStill`
  alarms prove the size and lens of every still.
- The frame-by-frame read of a screen recording (`ffmpeg … tblend=difference,signalstats`)
  is the feel-check that needs no instrument: frozen = missing frames, jump =
  one large delta.

## 5. Ideas not done (potential further exploration)

- **Fire → recorded ≈1.0 s** is the camera's own processing plus registration
  (write, auto-apply, project document, poster, PicPlace records push). Make the
  UI ready for the next shot at `didFinishProcessingPhoto` and let registration
  finish behind it; measure the registration half on its own.
- **AE settle before the first still** still applies when the exposure is
  converging; consider `photoOutput.capturePhoto` with the format's zero-shutter-lag
  path (`isZeroShutterLagEnabled`, `isResponsiveCaptureEnabled`) for Photo.
- **`awaitFocusSettle` blocks the session queue** for up to 1.5 s + grace; a
  KVO-driven wait would let a shutter press queue behind a tap without delay.
- **The launch splash covers 3 s** of a 5.5 s time-to-interactive; the walk and
  the export are the rest — an incremental walk (only folders whose mtime moved)
  would remove most of it on a library that did not change.
- **Watch link noise**: skip `updateApplicationContext` when no Watch is paired.
- **Thermal**: a `serious` state within minutes on USB with the camera open —
  worth a look at what the preview costs at 60 fps versus 30 (a switch back
  is one line).
- **`sessionQueue` visibility**: a signpost per queued block would show how long
  a press waits behind other session work.

## 6. Delays and gaps

- The Mac's data volume was full at 15:55 (167 MB free) — ~60 GB of old
  scratch DerivedData trees under `~/Library/Developer/LetsLapseRun/dd-*` were
  deleted (regenerable) before anything could proceed.
- Instruments on the 16 Pro (iOS 26.6): the App Launch template hangs and
  attach is refused; Time Profiler launches work. Its photo and launch numbers
  are log-based.
- `xctrace record --launch` never passes app arguments on a device and captured
  the app's signposts in one launched run of five; attach captures them — the
  harness launches through `devicectl` and attaches for C.
- The 18 Pro's after-run waits for the phone's return.
- This session sat paused on the Mac from about 17:35 to 21:00 (the clock
  jumped inside one tool call; nothing ran meanwhile), so the merged build's
  final 16 Pro runs happened at 21:05–21:30 rather than 18:00.
- A USB screenshot burst of the 16 Pro mid-shot (`idevicescreenshot`) produced
  no frames on iOS 26.6 — the chrome's stillness is argued from the code and
  the log, and left to Steven's eyes; a screen recording on the phone is the
  honest check.

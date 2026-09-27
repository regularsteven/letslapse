# Performance baseline — plan and results

A repeatable test for the three places LetsLapse feels slow on a big library,
so every performance fix is measured against the same run before and after.
Written 2026-09-27 from the iPhone 18 Pro's logs; the numbers in §5 that came
from logs are real, the trace numbers are still to be taken.

The rule: **no perf fix lands without a before and an after from this plan.**

---

## 1. Scope

Three scenarios, each run on its own:

| | Scenario | Starts | Ends |
|---|---|---|---|
| **A** | Cold launch | process start (`devicectl … launch`) | the app is interactive — first frame of the capture screen, **and** the launch work is done: `library: walked`, `library export: regenerated`, `picplace: check (…)` logged |
| **B** | Settings tab on a fresh launch | the tap on the Settings tab | the first frame in which the Settings list scrolls under a finger |
| **C** | Photo capture | the shutter press (Photo mode) | the shot is confirmed — the project is registered (`assets: … recorded`) and the capture screen is ready for the next press |

A and B are the two confirmed slow areas; C is the delay Steven reported on
2026-09-27.

---

## 2. Conditions — pinned for every run

Write every one of these into the run's row in §5. A run that breaks one is
not comparable; note why and re-run.

| Condition | Value | How to check |
|---|---|---|
| Device | iPhone 18 Pro, UDID `00008160-0008444E2280000A`, **on USB** | `xcrun devicectl list devices` shows it `connected` |
| Build | **Release**, `ios-app` branch, clean tree | `git status --short` empty; note `git rev-parse --short HEAD` |
| Library | 1,325 projects · 298 blends in the export (292 in the index — see §6) · bound to PicPlace @regularsteven | snapshot below |
| Network | Wi-Fi on, PicPlace reachable — **or** deliberately offline (Airplane mode + Wi-Fi off). Say which | the launch log shows `picplace: session … tokens found` and a `check (…)` line when online |
| App state | terminated before each run | `xcrun devicectl device process terminate` (below) |
| Sync | nothing sending | a log pull shows no `uploading N of M` and no `queued to send` > 0 in the last few minutes |
| Thermal | nominal | the phone has rested 2 min since the last run; the last `capture: photo — … thermal nominal · pressure nominal` line says so |
| Screen | unlocked, Auto-Lock → Never for the session | a locked phone refuses `devicectl` launches |
| Other controllers | LetsLapse Mac app closed | it holds a remote pairing that can connect mid-run |

`sysctl machdep.xcpm.cpu_thermal_level` is a Mac setting and says nothing about
the phone. The phone's thermal state is in its own log (`thermal …` /
`pressure …` on every capture line); the 2-minute rest is the practical rule.

### Commands

Set once per session:

```bash
UDID=00008160-0008444E2280000A
LIB=A4B0004C-AF54-48E5-BAB0-16AE963A12D4
SHA=$(git rev-parse --short HEAD)
DAY=$(date +%Y-%m-%d)
mkdir -p LetsLapse/docs/traces
```

Build and install. Use an isolated DerivedData so the shared one isn't disturbed. Release is what the scheme's Run action builds; a Debug build compiles the Kit `-Onone` and is useless for timing:

```bash
xcodebuild -project LetsLapse/LetsLapse.xcodeproj -scheme LetsLapse -destination 'generic/platform=iOS' -configuration Release -derivedDataPath /tmp/ll-dd-perf -allowProvisioningUpdates build
```

```bash
xcrun devicectl device install app --device $UDID /tmp/ll-dd-perf/Build/Products/Release-iphoneos/LetsLapse.app
```

The Release build is signed with `get-task-allow` = true, so Instruments can
attach to it (checked 2026-09-27).

Snapshot the library, which is how two runs prove they measured the same library:

```bash
xcrun devicectl device copy from --device $UDID --domain-type appDataContainer --domain-identifier com.regularsteven.letslapse --source "Library/Application Support/LetsLapse/Libraries/$LIB/Projects/library.json" --destination /tmp/ll-perf-library.json
```

```bash
python3 -c "import json;d=json.load(open('/tmp/ll-perf-library.json'));print(d['generatedCaptures'],'captures',d['generatedBlends'],'blends')"; shasum -a 256 /tmp/ll-perf-library.json | cut -c1-16
```

2026-09-27: `1325 captures 298 blends`, SHA-256 `d0219fd9233491e9…`. The
export has no timestamp at its top level and came out at the same byte size
on every rebuild that day, so the SHA should hold while the library is
unchanged — confirm on the first run. (`--destination` must be a file path
for a single file; a directory fails.)

Pull the logs (the pre-run sync check, and the post-run evidence):

```bash
xcrun devicectl device copy from --device $UDID --domain-type appDataContainer --domain-identifier com.regularsteven.letslapse --source "Library/Application Support/LetsLapse/Logs" --destination /tmp/ll-logs-18pro/
```

Terminate before each run:

```bash
xcrun devicectl device process terminate --device $UDID --pid $(xcrun devicectl device info processes --device $UDID 2>/dev/null | awk '/LetsLapse.app\/LetsLapse/{print $1; exit}')
```

(If that finds no pid the app is not running. That's fine.)

---

## 3. Capture method

One template per recording. `xctrace` cannot record two templates at once, so
"paired" means a second run under the same conditions. Every trace goes to
`LetsLapse/docs/traces/baseline-<scenario>-<date>-<sha>[-<template>].trace`.

⚠️ **Traces are large (tens to hundreds of MB) and must not be committed.**
`LetsLapse/docs/traces/` is not git-ignored yet. Add `LetsLapse/docs/traces/*.trace`
to `.gitignore` before the first run, or keep them outside the repo and note the
path in §5.

**The log is the clock that ties it together.** `LLog` writes to stdout and
`Logs/console-<launch>.log`, **not** to the unified log, so its lines do not
appear in the trace. Match trace time to log time by the wall-clock stamp on each
console line: note the Mac's clock when you start `xctrace`, and the phone's
clock is the log's. Adding `os_signpost` intervals for the launch walk, the
export, the PicPlace check and a photo's press → fire → recorded would put these
phases in the trace itself. That's the first instrumentation to do (TODO), and
the §4 targets assume it's not there yet.

### A — Cold launch

```bash
xcrun xctrace record --device $UDID --template 'App Launch' --output LetsLapse/docs/traces/baseline-A-$DAY-$SHA-launch.trace --time-limit 30s --launch -- com.regularsteven.letslapse
```

```bash
xcrun xctrace record --device $UDID --template 'Time Profiler' --output LetsLapse/docs/traces/baseline-A-$DAY-$SHA.trace --time-limit 30s --launch -- com.regularsteven.letslapse
```

- The **App Launch** run gives process start → first frame directly. The
  **Time Profiler** run shows where the first 30 s go.
- On the phone: **don't touch it.** A launch without hooks opens the capture
  screen by itself and starts the camera; let it sit for the whole 30 s.
- Run each three times, terminating between runs, and record the median.

### B — Settings tab

```bash
xcrun xctrace record --device $UDID --template 'Time Profiler' --output LetsLapse/docs/traces/baseline-B-$DAY-$SHA.trace --time-limit 30s --launch -- com.regularsteven.letslapse
```

```bash
xcrun xctrace record --device $UDID --template 'SwiftUI' --output LetsLapse/docs/traces/baseline-B-$DAY-$SHA-swiftui.trace --time-limit 30s --launch -- com.regularsteven.letslapse
```

- On the phone, in the same order every run:
  1. Wait until **10 s** after launch. By then the walk, the export and the
     PicPlace check are done (≈3.5 s today), so B measures Settings and not
     the launch.
  2. Close the capture screen.
  3. Tap **Settings** and note the Mac's clock time.
  4. Wait 2 s, then flick the list once.
- A second variant is worth one run each: tap Settings **as soon as the tab bar
  shows**, inside the launch window. Label it `B-early`. That's the real-world
  case where launch work and Settings pile up.
- Hands-free option: a Release build with DEBUG hooks can open Settings from
  launch (`LL_TAB=settings`). The recipe is in CLAUDE.md under *Connected asset
  states*: `SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG $(inherited)'`, then
  `devicectl … launch -e '{"LL_TAB":"settings"}'`. Hooks stop the camera from
  opening on its own, so this is a different launch from A. Record it as its
  own scenario (`B-hook`), never as B.

### C — Photo capture

```bash
xcrun xctrace record --device $UDID --template 'Time Profiler' --output LetsLapse/docs/traces/baseline-C-$DAY-$SHA.trace --time-limit 60s --launch -- com.regularsteven.letslapse
```

- On the phone:
  1. Wait 10 s after launch.
  2. Choose Photo mode.
  3. Take **10 shots**, one every ~5 s, in this lens order: 1× ×4, then 0.5× ×3,
     then 4× ×3. Changing lens is part of the cost; see §4.
- Fix the scene and the light: a tripod, the same subject, the same room light.
  AE settling (`waiting up to 2.0s`) is part of press → fire, and the scene
  decides it.
- **The test card rig** (`LetsLapse/tools/testcard/`) is the controlled light
  source for this: run `index.html` fullscreen on the monitor and aim the phone
  at it. What the rig measures is **not** capture latency. It stamps
  display-side time into every *video* frame, for frame-to-frame timing, ramp
  switch gaps and AE stability in Video mode, and it only arms in Video mode.
  Here it serves two purposes:
  - It's a fixed, known scene, so AE settles the same way every run.
  - For a ground-truth check of the log's press time, film the phone's screen
    and the card together from a second camera. The card's time QR gives the
    press frame and the shutter animation frame to ±½ frame.
- "Capture latency" in this plan means **press → confirmed**, split into
  press → fire (the app and the camera getting ready) and fire → recorded (the
  photo coming back and being saved as a project).

---

## 4. What to look for

### A — Launch

- **Time to first frame**, from the App Launch trace.
- From the console log of the same launch:
  - `library: walked N documents in X s`. 1.35–1.46 s on 2026-09-27.
  - `library export: regenerated from the documents in X s`. 1.17–1.49 s.
    **This should not happen at all on a clean library**: it's the blend
    mismatch in §6. Once that's fixed, the line should be absent from launch.
  - `picplace: check (…)`: note the time from the first log line to this one.
- In Time Profiler:
  - Main-thread samples in the first 5 s. The walk and the export run on the
    persister's serial queue (`LibraryPersister`), not on main.
  - Anything on main that waits on that queue: `persist(waiting: true)`,
    `queue.sync`, `flush()`. That's how off-main work still stalls taps.

### B — Settings

- In Time Profiler, main-thread time under `PicPlaceController.refreshFreeUpEstimate()`.
  The Settings PicPlace card calls it every time it appears
  (`.task(id: picplace.canSync)`, `App/PicPlace/PicPlaceViews.swift`). Its callees:
  - the candidate list: `LibraryIndex.projects` (every row) and a
    `model.capture(id:)` plus a record lookup per project. This runs on main.
  - the folder listing: `heavyFiles(in:)` per project. This runs on a detached
    task, off main.
  - back on main, per project: `looksOnPicPlace` → `PicPlaceOriginalsCheck.digest`
    / `notCovered` over every file of every project. Stack projects hold
    650–1,500 files each.
- In the SwiftUI trace:
  - how many times `SettingsView.body` is evaluated in the second after the tap;
  - long view updates;
  - any hitch in the first scroll.

  `picplace.freeUp` is `@Published`. The estimate sets it twice (`isEstimating`,
  then the result), and each set redraws the card and whatever else observes
  the controller.
- The metric: tap → first scroll frame. Main-thread busy time between the tap and
  that frame is the supporting number.

### C — Photo capture

The log already brackets every shot. The first log line after a press is the
lens pin (`optics: run pinned to …`); the photo run pins one lens per shot:

| Phase | From | To |
|---|---|---|
| press → AE wait | `optics: run pinned to <lens>` | `exposure: AE/AWB still settling at run start` |
| press → fire | `optics: run pinned to <lens>` | `capture: photo — …` |
| fire → recorded | `capture: photo — …` | `assets: <id> recorded` |

Parse them with the snippet in §7.

In the trace:
- The fire to `AVCapturePhotoCaptureDelegate.photoOutput(_:didFinishProcessingPhoto:error:)`.
  That's the camera's own processing, and the app can't change it.
- Then from the delegate to the UI saying the shot is done. This part is
  LetsLapse's: writing the file, auto-apply, registering the project, the
  poster, and the PicPlace records push that follows each new photo.
- Main-thread time between the two.

`checkDeliveredStill` (`ALARM` lines) and the `stills self-test` line are
supporting evidence (right size, right lens), not the measure. The self-test took
18 ms at camera set-up on 2026-09-27, so it's not the delay.

---

## 5. Baseline numbers

**How the rows were taken (2026-09-27, afternoon).** Commit `3eaad79` = the
code of `67c8cdc` plus signposts, a `thermal:` log line and the shutter press
in the log; the traces are in `docs/traces/` (git-ignored) and were recorded
with `tools/perf_baseline.py`, hands-free: A is `xctrace --launch` (App Launch
×3, Time Profiler ×1), B is the hooks build launched with `LL_TAB=settings`
(Time Profiler, SwiftUI, Animation Hitches), C is the app launched through
`devicectl` with the camera and remote-access launch arguments, Instruments
attached, and ten Photo shots over the Camera remote (1× ×4, 0.5× ×3, tele
×3, ~6 s apart). Library: 1,325–1,378 projects (it grew by the day's shots),
PicPlace bound and online, Wi-Fi. Hangs are the Hangs instrument's
`HangInterval`s (main thread unresponsive ≥ 250 ms); "busy" is running
main-thread samples.

### iPhone 18 Pro — before (3eaad79)

| Scenario | Metric | Value |
|---|---|---|
| A · launch (nominal) | process start → first frame (`ApplicationFirstFramePresentation`) | 1.00 s |
| A | `library walk` | 1.33–1.70 s (persister queue) |
| A | `library export` regenerated | 0.70–1.45 s — every launch (§6) |
| A | `picplace check` (foreground) | 3.5–4.3 s to its log line |
| A | main-thread hangs in the first 6 s | 3–4 hangs, 0.36–0.93 s each, ≈2.5 s together |
| A | one more hang at +21 s | 0.6 s (`scheduleAssetBackfill`: `liveCaptures` + `assetNames` on main) |
| A | main thread busy, first 5 s / next 5 s (Time Profiler run) | 1.9 s / 0.65 s |
| B-hook · Settings (serious!) | `settings appear` after launch | 2.0–2.3 s |
| B-hook | free-up estimate: candidates (main) / listings (off main) / judge (main) | 0.34–0.40 s / 2.2–4.8 s / 0.55–0.93 s |
| B-hook | main thread busy in the 3 s after appear | 2.4–2.8 s |
| B-hook | hangs from 3.5 s to 14 s | 13 hangs, ≈10 s together (0.28–1.5 s each) |
| B-hook | what the hangs run | `CaptureProject.init(from:)` decodes under `PicPlaceController.disconnectSummary()`, `updateTally()` (+ `LibraryIndex.projectID(originID:)`), `SettingsView.librariesCardPhone`, `AppModel.source(for:)`/`posterURL(for:)`, `LibraryIndex.upsertAssets` |
| C · photo (nominal → fair; 33 shots) | pin → fire, same lens / after a lens change | median 1.0 s / 1.4–1.8 s |
| C | fire → recorded | median 1.02 s (0.87–1.24) |
| C | press → fire → run flag on → run flag off → recorded (attached trace, 1× ×3) | 0 → 1.29–1.41 s → same → 2.27–2.40 s → 2.34–2.45 s |
| C | `lens pin` (input swap in) / `lens pin release` (swap out) | 0.28–0.35 s / 0.53–0.62 s — both black out the viewfinder |
| C | `AE settle` on the swapped-in lens | 0.56–1.17 s on every shot |
| C | `applyCaptureFormat` after a lens change | 0.67–0.70 s + 0.17 s |
| C | main thread busy per shot (press → recorded) | 107–150 ms |
| C | main-thread hang after every shot | 0.47–0.63 s — `PicPlaceController.updateTally()` walking the library |
| video 15:23 (serious) | Settings scroll: smooth / frozen / one-frame jump / frozen / smooth | 0.3 s / 0.9 s / — / 0.85 s / rest |
| video 15:23 | photo: press → chrome collapses → chrome back with progress row → row gone | 1.2 s → 2.2 s → 3.7 s |

### iPhone 16 Pro — before (485fcd9 = 3eaad79 + harness)

Instruments on this phone (iOS 26.6 from Xcode 27.0): the App Launch template
hangs and attach is refused, Time Profiler launches work — so C and A are
log-based here (`C-log`, `A-log`), B is a trace.

| Scenario | Metric | Value |
|---|---|---|
| A-log · launch (serious) | `library walk` | 2.0 s (log); 1.87 s cool |
| A-log | `library export` regenerated | 1.94 s — every launch |
| A-log | first line → `picplace: check (foreground)` | 2.7–2.9 s |
| A-log | first line → capture preview created (Open Camera on Create tab ON here) | 2.85–3.7 s |
| B-hook · Settings (nominal) | free-up estimate: candidates / listings / judge | 0.49 s main / 4.37 s off main / 0.61 s main |
| B-hook | hangs from 4.7 s to 18.3 s | 20 hangs, 13.6 s together (0.5–1.3 s each): `disconnectSummary`, `source(for:)`/`posterURL`, `updateTally`, libraries card, every one decoding all 1,363 project documents on main |
| C-log · photo (nominal → fair; 10 shots) | pin → fire, same lens / after a lens change | 0.15–0.47 s / 1.13–1.49 s |
| C-log | fire → recorded | median 1.41 s (1.05–1.55) |
| C-log | pin → recorded | median 1.62 s (1.49–2.87) |

From the 15:44 recording (thermal fair): Settings did not move for ≈6 s
after the tap; the tele joined the session on 1920×1080 and needed 0.44 +
0.16 s of format work before its still.

### iPhone 16 Pro — after the Photo change (WP1: combined camera + locked switching, no run focus pin, chrome stays), serious

| Metric | Before | After |
|---|---|---|
| press → fire, 1× and 0.5× (same lens) | 0.15–0.47 s | **0.00–0.01 s** |
| fire → recorded | 1.05–1.55 s | **0.58–0.70 s** |
| press → recorded, 1× and 0.5× | 1.5–1.8 s | **0.58–0.71 s** |
| lens swaps per shot (`optics: run pinned` / `released`) | 2 | **0** (switching locked 0.55 s, restored) |
| press → fire at 5× | 0.35–1.49 s | 2.0 s ✗ — `exposure: still settling after 2.0s` on the combined camera's tele; the single-still wait is now capped at 0.35 s (next run) |

### iPhone 16 Pro — after, with the single-still wait capped at 0.35 s (f8284f4), serious

| Metric | Value |
|---|---|
| press → fire, 1× and 0.5× | 0.00–0.01 s |
| press → fire at 5× | 0.37–0.38 s (the cap) |
| fire → recorded | 0.55–0.69 s (first shot after launch 1.39 s) |
| press → recorded, 1× / 0.5× / 5× | 0.69–0.70 s / 0.55–0.59 s / 0.95–1.00 s |
| `capture: still delivered` splits fire → recorded | camera ≈0.43 s · registration ≈0.25 s |

### iPhone 16 Pro — merged build (908a2d1: + library passes off main + index schema 4), serious → critical

| Metric | Value |
|---|---|
| launch 1 | `index: rebuilt from the files — 1397 projects · 296 blends · 46630 assets in 18.34 s` (once, schema 4) |
| launch 2 | walk 2.1 s; the export regenerated once (1.43 s) because the day's 14 new photos had left it stale |
| launch 3 | walk 2.07 s; **no export regeneration** — the every-launch rebuild is gone |
| launch: PicPlace check's merge pass / tally | `picplace check pass: 1388 … read in 0.6–2.0 s off main` / `picplace tally: … 0.5–0.6 s off main` |
| photo 1× / 0.5× press → recorded | 0.59–0.67 s / 0.79–0.89 s (camera 0.41–0.45 s, registration 0.18–0.22 s) |
| photo at 5× | not measured: the last four shots were refused at **thermal critical** (by design) |
| Settings (B, at thermal **critical**) | hangs 4.7–18 s: **5, 2.67 s together** (was 20, 13.6 s); main busy in the 3 s after appear **0.59 s** (was 2.6 s); free-up estimate `candidates 1.67 s, listed 4.80 s, judged 0.05 s, all off main` |
| Settings (B): what the five hangs were | one ~0.4 s wait, four busy in `LibraryIndex.projectID(originID:)` from `PicPlaceController.refreshUsage(status:rows:)` — one index query per server row on main; moved off main after this run (not yet re-measured) |

### Simulator

Launch and Settings only (no camera, no Vision); see the dispatch log.

## 6. Known suspects (from the 2026-09-27 audit)

- **The blend index mismatch: the export is rebuilt on every launch and never
  settles.** Every launch logs `library.json lists 1325 captures and 298 blends,
  the index 1325 and 292 — the export will be regenerated`. The rebuild writes
  298 again, so the next launch finds the same gap. That's six blends in the
  documents but not in the index. It costs 1.2–1.5 s on the persister's serial
  queue at every launch, on top of the walk: about 2.7 s in which any waiting
  write stalls. TODO: *Library export rebuilt every launch: 6 blends not in the
  index*.
- **`refreshFreeUpEstimate()` on every Settings open** — measured: candidates
  0.34–0.40 s on main, listings 2.2–4.8 s off main, judge 0.55–0.93 s on main
  (it logs `picplace: free-up estimate — …` since 3eaad79). It is not alone:
  `disconnectSummary()`, `updateTally()` and the libraries card each walk
  the whole library on the main thread while Settings is open, decoding every
  project's document — the 13 hangs of §5. TODO: *Settings: the free-up
  estimate re-runs on every open* (now: every whole-library pass off main).
- **Photo capture delay — found (2026-09-27, traces).** Every Photo shot
  pins the stop's physical lens (an input swap, 0.3 s, viewfinder blacks
  out), waits for that lens's exposure to settle from scratch (0.6–1.2 s),
  fires, then swaps the combined camera back (0.6 s, second blackout); the
  run flag lifts ~1 s after the fire and the chrome follows it. Main-thread
  work is ~120 ms a shot. After every shot `updateTally()` walks the library
  on the main thread for 0.5 s. Fix (this branch): Photo shoots from the
  combined camera with constituent switching locked; chrome stays put; press
  acknowledged at once; the tally moves off main. The earlier leads, kept
  for the record:
  - **Changing lens adds 0.8–1.2 s before the shot.** Every shot where press →
    AE wait is non-zero is a lens join: the photo run pins the stop's physical
    lens (the one-lens-per-shoot rule, 2026-09-27), reapplies the format, then
    waits for AE. Same lens as last time: press → fire is ≈0.17 s. A new lens:
    0.9–1.6 s. The worst cases (2.9–3.2 s, 08:18–08:19) had press → AE wait of
    2.3–3.1 s.
  - **Fire → recorded never gets below ≈0.93 s** (median 1.19 s). The C trace
    splits this between the camera's processing and LetsLapse's saving,
    auto-apply and registration.
  - **3 of 141 shots stalled ≈9.6 s between fire and recorded**, with no log
    lines at all in the gap (10:05:38, 10:41:14, 11:27:25). The first was
    followed by `RuntimeError code=-11819 Cannot Complete Action` and a camera
    restart. That's worth its own look, apart from the everyday delay.
  - Also worth checking:
    - The library write queue during the export rebuild (the first ~2.7 s after
      launch): only matters for a shot in that window.
    - Each new photo is followed by a PicPlace poster and records push
      (`poster for …`, `records bundle`, `uploading 2 of 2`). It runs after
      `recorded`, but it shares the main actor with the next press.
  - Ruled out:
    - The stills self-test (18 ms, at camera set-up only).
    - The first-install push queue (121 records at 14:10, which had settled by
      14:18).

---

## 7. Comparing runs

1. Fix one thing per commit. Note its SHA.
2. Re-check §2: the same library snapshot (counts and SHA), network mode,
   thermal rest.
3. Run the same scenarios with the same template, the same on-device steps and
   the same number of repeats. Add rows to §5 with the new SHA.
4. **A fix is validated** when its key metric improves on this run **and** the
   next run agrees (no regression, the gain holds), and the other two scenarios
   haven't got worse.
5. If the library changed (new projects or blends), take a new "before" at the
   old commit on the new library first. Otherwise the comparison is void.

Per-shot numbers for C from a log pull:

```bash
python3 - <<'EOF'
import re, glob, statistics as st
def t(s): h, m, x = s.split(':'); return int(h)*3600 + int(m)*60 + float(x)
rows = []
for f in sorted(glob.glob('/tmp/ll-logs-18pro/console-*.log')):
    cur = None
    for line in open(f, errors='replace'):
        m = re.match(r'(\d\d:\d\d:\d\d\.\d+) \S+ +[\d.]+ (.*)', line)
        if not m: continue
        ts, msg = t(m.group(1)), m.group(2)
        if msg.startswith('optics: run pinned to'): cur = {'press': ts}
        elif cur is not None:
            if msg.startswith('exposure: AE/AWB still settling') and 'wait' not in cur: cur['wait'] = ts
            elif msg.startswith('capture: photo') and 'fire' not in cur: cur['fire'] = ts
            elif msg.startswith('assets:') and 'recorded' in msg and 'fire' in cur:
                cur['rec'] = ts; rows.append(cur); cur = None
for name, fn in [('press→fire', lambda r: r['fire'] - r['press']),
                 ('fire→recorded', lambda r: r['rec'] - r['fire']),
                 ('press→recorded', lambda r: r['rec'] - r['press'])]:
    v = [fn(r) for r in rows]
    print(f"{name}: n={len(v)} median={st.median(v):.2f}s min={min(v):.2f}s max={max(v):.2f}s")
EOF
```

It pairs each lens pin with the next `capture: photo` and `assets: … recorded`.
It covers Photo mode only; an Interval run pins its lens once for the whole run.

# Performance audit — hot phone during transfer, slow pull, render staggers

**Date:** 2026-08-29 · **Trigger:** iPad Air M3 pulling a 5.1 GB project from an
iPhone 12 Pro ("From another device…") ran far below expectations, the phone got
hot enough to need a cool pack, and its own UI lagged badly. Separately:
starting any render makes screen-to-screen transitions stagger on every device.
The run ended at 4.6 / 5.1 GB with `NWError 60 — Operation timed out` on the
iPad.

**Field outcome of that run:** the timeout is the client's TCP keepalive giving
up. The bulk link runs keepalive idle 20 s / 3 probes × 5 s
(`Shared/CaptureRemotePairing.swift:88-93`), so a serving phone stalled hard for
~35–60 s — which is what a thermally clamped device looks like — reads as error
60 on the other end. And because Phase 1 shipped with **no resume**
(`docs/project-transfer-plan.md` §4; every failure path calls
`abandonStaging()`, `Shared/ProjectTransferClient.swift:448-468`), the staged
4.6 GB was deleted on failure. A retry starts from byte zero.

---

## Verdict

Three real mechanisms, one measurement still owed:

1. **Render staggers (all devices):** every render publishes progress through
   `@Published` properties on `AppModel` — the root environment object — at up
   to per-engine-frame cadence. `ObservableObject` invalidation is
   object-level, so each tick re-evaluates the entire mounted view tree, plus
   an app-root `.onChange(of: model.progress)` doing work per tick, plus (Mac
   only) synchronous whole-file log reads per tick. This is a confirmed,
   code-level storm; no device evidence needed.
2. **Hot phone while serving:** the pump itself is light (raw reads + AES-GCM),
   but while serving, the phone: re-diffs the whole Projects list on every
   progress tick, performs full-RAW thumbnail decodes on demand for the other
   device's scrolling, walks the entire library per list request, keeps the
   screen and Wi-Fi (incl. AWDL advertising) lit for however long the slow
   transfer takes — and once hot, iOS's thermal clamp makes the transfer
   slower, which keeps it hot longer. A separate latent trap can add a running
   camera session underneath all of it (finding C).
3. **The wire speed itself is unmeasured.** The pump has a built-in 5 s
   heartbeat (`transfer-pump … ahead N MB, R MB/s, footprint M MB, thermal T`)
   that distinguishes the two possible bottlenecks in one line: **window
   `ahead` pinned near 32 MB = wire/receiver-bound; near 0–8 MB =
   serving-device-bound (disk/CPU/thermal).** It prints via `LLog` (`print`,
   not os_log), so it only exists when the app is launched with a console
   attached — see the measurement plan.

What the transfer stack does **right** (verified, don't re-litigate): raw
binary data frames, no compression, no hashing (`Shared/
ProjectTransferProtocol.swift:56-144`); real windowed-ack backpressure with a
per-chunk autorelease pool (`Shared/ProjectTransferServer.swift:613-818`);
client writes off-main and acks after the disk write
(`Shared/ProjectTransferClient.swift:555-583`); hardware AES-128-GCM TLS with
no background service class (`Shared/CaptureRemotePairing.swift:65-105`);
thumbnails asked once per row and persisted server-side.

---

## Findings

### A. App-wide progress invalidation storm — the render staggers

- `App/AppModel.swift:953-964` — `progress`, `statusMessage`, `jobFolderURL`,
  `jobLogLines`, `processingFramesDone`, `processingETADate` are all
  `@Published` **on AppModel**, observed by `ContentView` and effectively every
  screen. One write → whole-tree invalidation.
- `App/AppModel.swift:3941-3952` — `reportClipProgress` performs up to three
  `@Published` writes per callback and writes even when the value doesn't
  change (`progress = max(progress, …)`).
- Emitter cadences feeding it, each via its own `Task { @MainActor }` hop:
  - `Kit/…/ImageStacker.swift:152, 374, 550` — **every input frame** (the
    interval/photos path, i.e. the app's primary render). A 3,000-frame stack
    = 3,000 main-actor tasks × 3 published writes.
  - `Kit/…/TimeSliceRenderer.swift:401` — every master frame.
  - `Kit/…/VideoBlender.swift:433-435` — every 10th frame (fine).
  - `App/MacVideoJobRunner.swift:444, 642` — every 5th blend frame.
- `App/LetsLapseApp.swift:364-365` — app-root
  `.onChange(of: model.progress)` / `.onChange(of: model.processingETADate)`
  run `publishFlowContext()` (string building + watch-context comparison) on
  **every** tick.
- `App/MacVideoJobRunner.swift:855-874` — `sendProgress` appends to the job
  log (open/seek/write/close per line) **and re-reads the entire log file**
  (`recentLogLines`, :850) per emit → O(n²) disk reads over a job; the
  resulting array replaces `@Published jobLogLines` wholesale
  (`AppModel.swift:4709`).
- `App/MacVideoJobRunner.swift:452` — blend workers run at
  **`.userInitiated`** (default width = cores − 2, so ~14 on the M4 Max),
  competing with the UI during exactly the window transitions that stagger.
- Well-behaved counter-examples already in-tree to copy:
  `App/CompositionExporter.swift:200-205` (whole-percent throttle, comment
  says why), `App/AppModel.swift:7038-7048` (5 Hz sampled meter).

### B. Serving-side load on the phone

- `App/ProjectsView.swift:27, 179-186` — the transfer server is a
  `@StateObject` **of ProjectsView**, so every `activeTransfer` mutation
  re-evaluates the Projects body: `sourceCaptures` → `filtered` → `matching`
  → full `ForEach` re-diff (:48-57). Steady-state 5 Hz
  (`Shared/ProjectTransferServer.swift:788-791`), **unthrottled at file
  boundaries** (:702, :719) — hundreds/sec on a fast link with small files.
  This is the "scrolling is badly delayed" screen.
- `Shared/ProjectTransferServer.swift:397-404` — `replyWithList` re-walks
  **every project folder in the library** per `listProjects`
  (`AppModel.directorySize` over each, `App/AppModel.swift:3895-3914`).
  Off-main at `.utility`, but a real sustained burn on a big library.
- `App/AppModel.swift:7233-7249` — picker thumbnails are generated on demand
  on the serving phone; a cache miss on a DNG project = **full RAW decode**
  (iOS DNGs embed no preview), driven by the *other* device's scrolling.
  Bounded (once per row, persisted) but hot while the iPad browses.
- `includePeerToPeer = true` on listener and browser (server :128, client
  :128) keeps AWDL active on both ends for the whole session; the client's
  browser also stays alive during the pull
  (`App/ProjectTransferImportView.swift:38-50` only stops it on disappear) and
  delivers results on `.main` (`Shared/ProjectTransferClient.swift:153`).
  AWDL duty-cycling degrades infrastructure Wi-Fi throughput while it scans.
- Thermal feedback: hot → clamp → slower transfer → screen+radio lit longer →
  hotter. The observed endgame (stall long enough that keepalive kills the
  link, error 60 on the iPad) matches.

### C. Camera session can outlive the capture screen

`App/CaptureView.swift:1262-1291` — `cleanUpOnDisappear` stops steadiness,
taps, location, logging… **but never calls `camera.stop()`**. All button-driven
exits go through `closeCapture()` (:4144) which does stop it; any dismissal
driven by the `isPresented` binding (hooks, programmatic flows) leaves the
`AVCaptureSession` running with no screen. A live session is a constant
ISP/AE/AF load — precisely the "hot while idle" profile. One-glance field
check: the green camera indicator while sitting on the Projects tab.
Fix is a safe backstop: `camera.stop()` in `cleanUpOnDisappear` (Photo mode's
keep-alive is only for while the screen is up, so a backstop on disappear
cannot break it).

### D. No resume — the failed pull discarded 4.6 GB

Known Phase-1 scope (`requestTransfer` carries no `have` set; every failure
path drops the staged tree, `Shared/ProjectTransferClient.swift:463-468`).
Yesterday's failure turned that scoping decision into a real cost: ~75 min of
transfer discarded at 90%. Resume is designed (plan §4, reconciliation point
already marked at `App/AppModel.swift:7271-7283`); this audit promotes it.
Also: the raw `NWError 60` string reaches the user verbatim — worth a
sentence ("The other device stopped responding — it may have overheated or
left Wi-Fi") plus keeping the partial for the resume that §4 adds.

### E. Minor (collected)

- `App/MacVideoJobRunner.swift:721-724` — `usleep(2000)` readiness spin
  (~500 wakeups/s) during encode.
- `Shared/SteadinessMonitor.swift:56-66` — 50 Hz motion updates delivered on
  `.main`, publishing per sample while capture is up.
- `App/FullscreenMediaSheet.swift:594-616` — playback ticker keeps waking at
  frame rate while paused.
- `App/PhotoViewerView.swift:1237-1257` — 30 Hz main-actor playback loop
  (by design, but it is main-actor).

---

## Measurement plan (what plugging a device in buys)

Cable the **iPhone 12 Pro** to the Mac (Lightning/USB). Then:

1. **Heartbeat capture** — launch with a console and re-run a transfer:
   `xcrun devicectl device process launch --device <udid> --console
   --terminate-existing com.regularsteven.letslapse`
   and filter `transfer-pump`. Read: `R MB/s` (truth), `ahead` (≈32 MB =
   wire-bound, ≈0–8 MB = phone-bound), `thermal` (0…3 over time), `footprint`.
   NOTE: do not pass any `LL_*` hook env vars (they suppress normal startup),
   and a cabled phone is on Wi-Fi **and** USB at once — the connection usually
   settles on USB, which makes this an A/B in itself:
2. **A/B:** cabled pull fast (the 16 Pro benched 41 MB/s over USB) but Wi-Fi
   pull slow → the network path is the bottleneck (AWDL/2.4 GHz/congestion).
   Both slow → the phone is the bottleneck (thermal/CPU) → profile:
3. **Time Profiler** on the cabled phone during a slow serve
   (`xctrace record --template 'Time Profiler' --device …`) — 30 s answers
   "what is actually burning" definitively.
4. **Zero-cable checks meanwhile:** green camera dot on the Projects tab
   (finding C); Settings ▸ Battery ▸ battery usage by app right after a hot
   session (whether LetsLapse or the system's own radios took the energy).

Practical note for *this* 5 GB project: a cabled iPhone → Mac import is
minutes, not hours, and skips the radio entirely. Serving is bounded by where
the library lives, so pulling on the Mac is the fast path today; iPad can pull
from the Mac afterwards if it needs its own copy.

---

## Measured run (2026-08-29, cabled)

Same project, same serving phone, USB instead of Wi-Fi: iPhone 12 Pro (cool
start, capture screen closed, Projects tab, screen on) → `transfer_probe` on
the Mac, phone console attached via `devicectl … --console`.

**Result: 5.09 GB / 443 files in 404.6 s = 12.6 MB/s average, byte-for-byte
verified (`TRANSFER PASS`), clean drain, `error=none`.**

- **Rate:** 17.6 MB/s peak cold, settling to 10–13 MB/s.
- **Thermal (`ProcessInfo` digit in the heartbeat):** 0 → 1 at ~1.0 GB (~90 s
  in) → **2 (serious) at ~1.7 GB (~2.5 min in)**, pinned at 2 to the end,
  never 3. The rate sag tracks the digit — mild clamping is visible even on
  USB with no camera and no Wi-Fi.
- **Ack window:** `ahead` pinned at 26 of 32 MB for the entire run — the
  server always had data framed and waiting, so pacing came from the
  receiver/wire side. The phone-side pump, flash reads and TLS are healthy.
- **Footprint:** 60–86 MB throughout (backpressure + per-chunk pool working
  as designed).

**Reading for the Wi-Fi incident:** with the pump proven good and the device
sustaining 12.6 MB/s while thermally *serious*, the Wi-Fi run's rate — far
below this for over an hour — has to be the radio path (AWDL duty-cycling
while listener+browser advertise peer-to-peer, band/congestion, distance),
compounded by the thermal spiral: at Wi-Fi pace the phone sits at thermal ≥2
with the screen lit for the whole job, and the endgame is a stall long enough
for the client's 35 s keepalive to conclude death (`NWError 60`). "Crazy hot"
is the current design's expected serving posture on an A14, not a rogue
process — the serving-load fixes below are the lever. A follow-up Wi-Fi pull
with the console attached (the cable only carries the console; an iPad client
connects over Wi-Fi regardless) would put numbers on the radio path itself.

## Measured run 2 (2026-08-29, Wi-Fi, both consoles attached)

Immediately after the USB run (phone pre-warmed to thermal 2), the real iPad
import was repeated over Wi-Fi with `devicectl --console` on both devices —
the cables carry only the consoles; the data path stays radio.

| t (from serve start) | sent | rate | ahead | thermal |
|---|---|---|---|---|
| ~5 s | 0.04 GB | 7.4 MB/s | 29/32 MB | 2 |
| ~75 s | 0.16 GB | 2.0 MB/s | 26/32 MB | 2 |
| ~160 s | 0.31 GB | **1.3 MB/s** | 26/32 MB | **3 (critical)** |
| ~260 s | 0.45 GB | 1.3 MB/s | 26/32 MB | 3 |

**The isolation:** same phone, same project, same thermal-2 starting state —
USB sustained 12.6 MB/s; Wi-Fi opened at 7.4 and collapsed to 1.3 MB/s with
the ack window **pinned full the whole time** (the server always had data
framed and was waiting on the wire). The radio path is the bottleneck, and
the radio work itself is the heater: the USB run never left thermal 2 at 6×
the throughput, while Wi-Fi serving reached **critical inside three
minutes**. At critical, iOS clamps CPU/GPU/radio — the crawl, the dimmed
laggy UI, and (given ~65 min of exposure) the eventual stall that trips the
client's 35 s keepalive (`NWError 60`) are all one state. Yesterday's
failure is fully reproduced and explained. Footprint on the slow wire sat at
~150 MB (vs ~75 on USB) — the in-flight window riding in `NWConnection`'s
buffer, not a leak.

**30 s Time Profiler during the crawl (thermal 3, 1.3 MB/s):** 9,886 samples
≈ 0.33 core-equivalents — the app is ~95 % idle. **93 % of samples are on
the main thread**; the pump's queues total ~2 %. Unique hot frames: kernel
TCP + `Encrypt_Main_Loop` (thin), then `URLComponents`, `SwiftURL.path`,
`String` building and `AppModel.source(for:preferring:)` — i.e. ProjectsView
row content re-resolved per progress invalidation (finding B), running on
thermally clamped cores. There is no hidden CPU burner; the app's own
contribution to the heat is the radio duty plus main-thread re-rendering.

**Practical consequences:** big projects should move over the cable (USB to
the Mac, minutes) or via a Mac relay (Mac serves iPad afterwards — Phase 3
path, thermally trivial); phone-to-iPad Wi-Fi transfers of many GB will sit
at thermal ≥2 for their whole duration until the serving-load fixes land,
and remain hostage to whatever the radio path gives. The always-on
peer-to-peer advertising (both devices' transfer listeners + the client's
browser stay up during a pull) is a candidate multiplier worth an A/B once
the P2 fixes land.

## Measured run 3 (2026-08-29 evening, direct peer-to-peer — the fix)

After the `includePeerToPeer` flag landed on `PTLink`'s data connection
(Phase D — the field case had been broken by its absence: P2P discovery, no
P2P data path), the same import was run with the devices on **different**
SSIDs — no router in common, a faithful no-Wi-Fi field simulation:

**`link ready via awdl0` on both ends → 5.09 GB in ~173 s ≈ 29 MB/s average
(32.8 peak), thermal 0 throughout, and the ack window ran at `ahead 3 MB` —
near-empty: for the first time all day the WIRE outran the phone.** The
project installed on the iPad. Direct AWDL is 15–30× the router path in this
environment and finishes before heat can accumulate — the thermal problem
dissolves when the transfer is short.

Full run ladder, same phone, same 5.09 GB project, one afternoon:
| path | rate | thermal | outcome |
|---|---|---|---|
| USB to Mac (probe) | 12.6 MB/s | 0→2 | verified, 6¾ min |
| 2.4 GHz infra, hot start | 7.4→1.3 MB/s | 2→3 | cancelled |
| 2.4 GHz infra, cool pack (thermal 0!) | 3.6→0.9 MB/s | 0 | cancelled — **thermal exonerated; the link was the wall** |
| **AWDL direct, cross-SSID** | **~29 MB/s** | **0** | **imported, ~3 min** |

**Same-LAN answer (measured same evening):** with both devices on one SSID,
Network.framework STILL chose `awdl0` — no direct-first policy needed on
these devices/OS. Confirmed at scale immediately after: a **10.1 GB / 913
file** pull over same-LAN AWDL ran ~525 s ≈ **19.2 MB/s average** (21.7
peak), thermal reaching only 1 (fair) at the 7 GB mark, `error=none`,
installed. Day total: 15.2 GB moved phone→iPad through the air after a
morning where 4.6 GB took over an hour and died. The router is out of the
transfer business.

Also decided: the transfer dim comes back out (3–9 minute transfers don't
need it; the keep-awake stays) — a duration-aware dim can return via the
Phase-C design pass if long pulls reappear.

**Session side-findings:**
- The installed phone build is **Release**, so every `LL_*` hook is compiled
  out — bench automation against this device silently degrades to a normal
  launch (which auto-opens the camera; it was closed by hand for the run).
- The transfer listener arms at app launch on any tab — `ProjectsView.onAppear`
  fires eagerly — so a sharing-enabled phone advertises over Bonjour/AWDL for
  the whole life of every app session.
- The TXT record's project count is stamped at listener start, before the
  library loads: the picker banner said "0 projects" for a 15-project phone.
- `UIDevice.current.name` in this build is the generic "iPhone" (no
  user-assigned-name entitlement), which broke `transfer_probe --device`;
  the probe now also matches the Bonjour instance name (fixed this session).
- The unpaired-Watch `updateApplicationContext` failure burst at launch is 9
  calls in ~4 s, then silent — noisy, not hot.

## Ranked fixes

**P1 — render staggers (one change-set):**
1. Gate at the sink: throttle `reportClipProgress`/`reportTailProgress` to
   5–10 Hz (or adopt the sampled-meter pattern from `AppModel:7038`).
2. Move run-progress state (`progress`, `statusMessage`, `jobLogLines`,
   frames/ETA) off `AppModel` onto a small `ProcessingProgressModel` observed
   only by the processing screens; feed the watch context from its throttled
   output and delete the per-tick `.onChange` at `LetsLapseApp:364-365`.
3. Ring-buffer the Mac job-log tail in memory; one persistent `FileHandle`
   for appends (`MacVideoJobRunner:850-874`).
4. Throttle `ImageStacker`/`TimeSliceRenderer` emits to `% 10` like
   `VideoBlender` (defence in depth below the sink gate).

**P1 — heat backstop:** `camera.stop()` in `cleanUpOnDisappear`
(`CaptureView:1262`).

**P2 — serving polish:** throttle the per-file `onProgress`
(`ProjectTransferServer:702`); hoist the sharing chip into its own observer so
`activeTransfer` can't re-diff the Projects List (`ProjectsView:27,179`);
short-TTL cache for `replyWithList`'s catalogue walk
(`ProjectTransferServer:397`); pause the client's browser while a pull is in
flight (`ProjectTransferClient` / `ProjectTransferImportView`); consider
`isIdleTimerDisabled` + the existing screen-dim treatment while
serving/pulling.

**P2 — resume (plan §4):** send a `have` set on `requestTransfer`, keep
partials on failure, reconcile sizes on restart. The 4.6 GB discard is the
motivating incident. Friendlier timeout message rides along.

**P3:** `.userInitiated` → `.utility` for Mac blend workers (or a
UI-responsiveness mode), encoder readiness via
`requestMediaDataWhenReady` instead of the usleep spin, SteadinessMonitor
off-main/decimated, paused-ticker fix in `FullscreenMediaSheet`.

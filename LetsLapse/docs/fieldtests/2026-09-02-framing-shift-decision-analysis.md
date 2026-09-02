# iPhone 12 Pro framing shift — analysis against the decision brief (2026-09-02)

Companion to `2026-09-02-framing-shift-pattern.md` (the corpus sweep). This
answers the decision brief's two options and names the one lever the corpus
points at that has not been pulled. No code was changed; TODO.md untouched.

## Option 1 — disable OIS: no route

- **Public API: none.** `AVCaptureDevice` exposes nothing for the optical
  actuator. `preferredVideoStabilizationMode` is electronic stabilization
  and is already irrelevant to these frames (only the video-mode movie
  output ever sets it). No format, preset or photo-settings flag touches
  OIS.
- **Private API: not a product route.** Even if a private selector exists
  it cannot ship through App Review and cannot be relied on across iOS
  versions. It could only ever be a bench diagnostic, so it does not
  satisfy "demonstrated, not assumed" for a shipping device.
- **Physics: no help.** The sag is gravity-aligned. Pointing the optical
  axis along gravity would zero it and is useless for a landscape.

Plainly: there is no way to hold the lens still. Option 1 is closed.

One reframing matters, though. The step is not the actuator overheating
on its own schedule: in all three post-gate runs it lands in the same
2–3 s window as the OS's `serious → critical` transition. It is a system
action that comes *with* the critical level. So "hold the lens still" and
"never enter critical" are the same requirement, and that is option 2.

## Option 2 — a proven envelope: plausible, and the corpus says which lever

### What the runs say about heat

| 12 Pro run | path | depth · interval | time to critical |
|---|---|---|---|
| F6F7FCC8 | JPEG video tap | 1 · 2 s | 16 min |
| 8B6C7BFC | JPEG video tap | 10 · 2 s | 13 min |
| FC69DAEB | JPEG video tap | unthrottled · 3 s | 16 min |
| CBD2B71A | JPEG video tap | unthrottled · 3 s | 12 min |
| 1FB0FD23 | JPEG video tap | unthrottled · 3 s | never (72 min at serious) |
| 3355871A | DNG photo output (tele, OIS) | 1 · 1 s | never (73 min at serious) |
| B94D8940 | DNG photo output (wide) | 5 · 5 s | never (64 min at serious) |
| 907DD068 | DNG photo output (wide) | 5 · 5 s | never (34 min at serious) |

Depth 1 at 2 s reached critical as fast as unthrottled. The JPEG Dynamic
path streams the full 4032×3024 BGRA tap at the pinned 30 fps for the whole
run — `applyCaptureFormat` sets min = max = 1/30 and the blend start only
*raises the maximum* for ramped runs — so a depth-1 run discards 59 of
every 60 frames while the ISP works flat out. The photo-output runs on the
same phone, including a 73-minute 1 s depth-1 run on the OIS telephoto,
never left serious. Dates and ambient differ between rows, so this is a
lead, not a proof, but it is consistent and it matches the 2026-08-25
bench finding that interval is not a lever (the stream runs regardless).

### Apple's guidance, which the app does not act on today

The SDK header for `AVCaptureDevice.systemPressureState` (iOS 11.1+,
camera-specific, KVO-able, with factors `systemTemperature`, `peakPower`,
`depthModuleTemperature` and, from iOS 17, `cameraTemperature`):

> System pressure can be effectively mitigated by lowering the device's
> activeVideoMinFrameDuration in response to changes in the
> systemPressureState. Clients are encouraged to implement frame rate
> throttling to bring system pressure down if their capture use case can
> tolerate a reduced frame rate.

Serious: "Frame rate throttling is advised." Critical: "Frame rate
throttling is highly advised." Shutdown: "Capture must immediately stop."
The app currently reads `ProcessInfo.thermalState` and the session
interruption reason only; `systemPressureState` is never observed.

### The candidate envelope (to be proven, not shipped)

1. **Stream at the rate the window needs.** Min frame duration =
   interval ÷ depth, clamped to the format's supported range (depth 1 at
   2 s wants 0.5 fps; a 1 fps floor is the usual lower bound and the 16 Pro
   probe's 1.0 s maximum exposure on every format implies 1 s frame
   durations are accepted; the 12 Pro's ranges need `LL_PROBE_FORMATS` on
   the connected device). Same lens, same format, same resolution — no
   product compromise, and it is a timelapse: it can tolerate a reduced
   frame rate by definition.
2. **Throttle on `systemPressureState`, not just log it.** At serious,
   drop the tap to the floor and cap ramp/blend depth; that is Apple's
   prescribed mitigation and it is camera-specific, so it can lead the
   ProcessInfo state.
3. **Or route depth-1 Dynamic through the photo output** the way the DNG
   path already does — the corpus's only 12 Pro runs that held serious for
   an hour.

Each of these keeps the pixels untouched. None is a mitigation of the
shift; they are ways of never reaching the state that causes it, which is
what the brief asks for.

## The guard that belongs in either outcome

The shift precedes the app's own observation of critical: the gate flagged
window 484 / 384 / 319 and the thermal record moved in 485 / 385 / 320. A
stop on the critical notification is therefore already one frame late.
The rule-compliant shape is: on critical entry (either observable), end
the run with `endReason: tooHot` and drop the trailing window(s); refuse
to *start* a Dynamic run at critical (E9D52934 shows a parked lens
re-centring spontaneously while critical); and do not gate on serious —
the phone held serious cleanly for 72 minutes (1FB0FD23). A shoot that
ends clean at minute 16 is recoverable; that is the brief's own test.

## The gate as the proof instrument — one caveat

`framingChanged` / `framingGlitch` are the right acceptance test on the
bench, where the scene is the static test card. They are **not** yet safe
as a stop trigger in the field: 6156BA32 (16 Pro, nominal, static tower
against drifting cloud) rejected 24 of 75 frames at "40 px" in window 79
while the output frames are pixel-identical (0.0 px between 78, 79, 80).
The row/column projection method reads cloud drift as a whole-frame shift.
Envelope validation should pair the gate with the sweep tool's per-frame
phase correlation on the pulled frames, which is the ground truth the
corpus was judged by, and any field stop policy needs the gate hardened
first.

## Bench plan (the brief's steps 1–3)

- **Repro.** 12 Pro on the test card, JPEG Dynamic at 2 s (today's path),
  screen dim on, warmest plausible ambient. Field runs reached critical in
  12–16 min; the 2026-08-25 bench hit it at T+5.9 min. Pull, run
  `framing_shift_report.py`, expect a stayed step in the transition window.
  If it does not reproduce, flag it — per the brief that changes the
  decision by itself.
- **Envelope arms**, ≥ 2 h each, three repeats, same ambient: (A) today's
  path as control; (B) tap at interval ÷ depth fps; (C) photo-output
  stills at the same interval; (D) B plus `systemPressureState`
  throttling. Pass = never leaves serious, zero steps in the sweep, zero
  `framingChanged`. "Highest resolution" is fixed (full sensor);
  "shortest interval" is measured per arm.
- **Margin.** Report the peak `systemPressureState` level and factors per
  arm, not just ProcessInfo; a pass that sat at serious for two hours has
  margin in a way CBD2B71A's 67 clean critical windows never did.
- **Controls.** Ultra Wide (no OIS) only as a control arm; 16 Pro driven
  to critical to test the sensor-shift immunity, which no logged run has
  reached.

If (B)–(D) all fail to hold serious in the warm-ambient repeats, the
brief's third outcome stands: the 12 Pro is not a supported device for
long-form Dynamic capture, and the app says so before hour three.

## Implemented 2026-09-02 (steps 1 and 2 of the recommendation)

**Step 1 — the stream throttle** (`CameraController.throttleBlendStreamForRun`,
`setStreamRate`, `applyPressureFloorToStream`). At blend start the video tap's
`activeVideoMinFrameDuration` is set to twice what the depth strictly needs
(depth ÷ interval), clamped to the active format's range; the maximum moves
out with it so min ≤ max holds at every write, and both are restored at run
end. Open-ended depths (Psycho, Auto) keep the configured rate until the
camera's own `systemPressureState` reports serious, at which point the
stream drops to what the depth needs (open depths to 3 fps) — Apple's
prescribed mitigation, applied for the first time. The run's stream rate is
in the experiment log header (`streamFrameRate`) and the camera's pressure
level with factors is stamped on every window (`systemPressureAtClose`) in
both the experiment log and `capture_log.json`.

**Step 2 — the critical stop** (`CameraController.installRunThermalGuard`,
`endRunTooHot`, `stopsAtThermalCritical`). On iPhones only (iPads have no
OIS), every run — video-tap blend, DNG blend, plain interval — arms two
observers: `ProcessInfo.thermalState` and the device's `systemPressureState`.
The device-wide state reaching critical — the trigger every logged step
sat on — ends the run with `endReason: tooHot`; the camera's own critical
level only throttles and is recorded (Apple's advice, not our data — no
evidence ties it to the OIS park, so no shoot is ended on a proxy), while
camera *shutdown* also ends the run because the OS ends capture there
regardless. Serious never stops anything: the corpus has 2653 clean
12 Pro frames at serious and a 72-minute run that held it. The stop's cost
in the corpus is small — of the five runs that entered critical, four
stepped (three at the transition) and the fifth spent 3.4 min at critical
before ending anyway; the two that stayed at critical both died of the OS
veto later. On the run it ends, the in-flight window is not kept, and the **last two
written outputs are deleted** together with their sidecar lines
(`FrameTimestamps.dropTrailingEntries`, also applied to the ramp-owned
sidecar on Holy Grail runs) — because on every logged event the framing
moved in the window that crossed into critical or the one before it, and
the app's thermal record moved one window later. A start at critical is
refused (`capture_refused` in the session log, readout status
"Too hot — stopped"), and the idle chip now says "Too hot to shoot — let it
cool first" instead of warning. `capture_log.json` gains `tooHot` and
`systemPressure` issue kinds.

**Bench hooks (DEBUG builds only):** remote command `simulateTooHot` fires
the stop on a running shoot exactly as the observers would; launch
environment `LL_REMOTE=1` stands in for the Allow-remote-access toggle and
`LL_STOP=<factor>` pins the lens stop, neither being a screenshot-mode hook
key. `remote_probe` recompiled against the updated Shared sources.

**Verified on the 12 Pro (2026-09-02, wide 1×, Holy Grail, depth 1 @ 2 s,
dim off, phone already at serious when it started):**

- Run 1 (stop plumbing): stream `10.00 → 1.00 fps` logged (this phone's
  configured rate was 10; the format floor is 1 fps); 23 windows produced,
  one frame each exactly on the 2 s grid; `simulateTooHot` → "TOO HOT …
  ending the run, last 2 output(s) will be discarded" → "finished
  outputs=21"; the run went idle on the next state push.
- Run 2 (thermal, 30 min, device-owned `scheduleStop`, started 11:02 UTC
  with the phone already at serious): **899 of 899 windows delivered, one
  frame each on the 2 s grid, zero missed, zero dropped, zero alignment
  rejects, never critical.** Device-wide state: serious → fair at 0.8 min →
  serious from 4.0 min to the end (804 serious / 95 fair windows); the
  camera's pressure state moved at exactly the same minutes with the
  `systemTemperature` factor. Yesterday's run on this phone with the same
  configuration (F6F7FCC8, depth 1 @ 2 s, wide, streaming at the pinned
  rate) reached critical at 16 min from a *nominal* start and stepped there.
  One run, one ambient, a warm start — not the envelope proof, but the
  first time this configuration has held serious for half an hour on this
  phone, and the direction is the one the corpus predicted.

- Run 3 (thermal, 30 min, Holy Grail, JPEG, flat, **10-blend @ 3 s**, wide
  1×, dim off, cool start at 12:35 UTC): **599 of 599 windows, never
  critical.** Stream 10 → 6.67 fps at start (2× the 3.33 fps need); nominal
  → fair at 2.5 min → serious at 4.8 min, where the camera pressure floor
  dropped the stream to 3.33 fps — and every window from there delivered
  **8 of 10** (501 windows at 8, one at 9; 97 at 10 before it), zero camera
  drops, zero alignment rejects. Yesterday's 10-blend @ 2 s on this phone
  (8B6C7BFC) reached critical at 13 min and stepped. The exact-need floor
  costs two frames per window (the selection grid has no slack at 1×) —
  **change the serious floor to 1.5× the need**.

## The setting (2026-09-02, afternoon)

Steven's call, with two changes argued in the thread: **Settings ▸ Advanced ▸
Performance ▸ Capture stream rate — Auto / Reduced / Full** (`StreamRatePolicy`,
`App/CaptureStreamRate.swift`). Named for what it does (the capture stream,
not the viewfinder — the preview only slows because it shares the stream),
and Auto reacts to the camera's live pressure state rather than counting
strikes: full rate while cool, the depth's need × 1.5 from serious, back to
the opening rate at nominal (not at fair — the runs oscillate fair↔serious
for minutes). Auto's self-learning: after three runs where the floor engaged
(`StreamRateLearning`), the device starts reduced (need × 2) from frame 0
and the settings row says so; choosing Auto again resets it. Reduced = start
reduced by hand; Full = never throttle (the critical stop still applies).
Fixed counts the stream cannot deliver with 25 % headroom are greyed on the
BLEND dial with "needs N fps", refused by the remote, and the chosen count
falls to the deepest attainable one when the interval changes under it.

- Run 4 (Auto, 10-blend @ 3 s, 10 min, warm start): opened at the full
  10 fps; serious at 1.5 min → floor **5 fps**; **199 of 199 windows at
  10 of 10** (run 3's 1× floor gave 8 of 10 in every window). The learning
  counter reads 1 after the run.

**Not verified on disk:** the run-1 project's file count after the drop
(the transfer server was not advertising after the run, and `devicectl`
cannot list the library). The controller logged "last 2 output(s)
discarded" and "finished outputs=21" from 23; the sidecar trim is covered by
Kit tests; the ramp-owned sidecar trim on Holy Grail runs is code-read only.
Check the project on the phone: 21 frames, 21 sidecar lines.

**Still owed:** the 2 h × 3 warm-ambient envelope arms (today's path as
control vs throttled), the open-ended depths' serious rate (3 fps, a named
constant), the idle thermal chip's SVG, and the remote-probe header note.
